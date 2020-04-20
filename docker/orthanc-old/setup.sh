#!/usr/bin/env bash
#
# OVERVIEW
#
# Execute a setup procedure for Orthanc.
#
# A single setup procedure can optionally write a single Orthanc
# configuration file ('conf' variable), can optionally enable one or
# more plugins ('plugin' and 'plugins' variables), and is provided with
# support facilities like 'log'.
#
# EXIT STATUS
#
# 1: No setup procedure path given (first argument)
# 2: No procedure name is defined in setup file ('name' variable)
# 3: Env-var set but no conf file path defined in setup file ('conf' variable)
# 4: No configuration generator defined in setup file ('genconf' function)
# 5: Obsolete (was: Internal error: trying to enable undefined plugin)
# 6: Procedure attempted to define both 'plugin' and 'plugins' variables
# 7: Unknown default marker in plugin selector
# 127: A command failed

set -o errexit
if [[ $BUNDLE_DEBUG ]]; then
	set -o xtrace
fi

# Specifying the target setup procedure path is mandatory
if [[ ! $1 ]]; then
	exit 1
fi

# Parameters set in setup procedures:
#
# name: The abbreviated name for the setup procedure set.
#
#   Mandatory.
#   Should be uppercase.
#   Should be quite short.
#   Will be used in log messages.
#   Will be used as prefix for environment variables.
#   Multiple setup procedures can use the setup procedure set name.
#
# plugin: Orthanc plugin shared library
#
#   Optional.
#   Can't be used with 'plugins'.
#
#   The name of the plugin (filename without path or extension) the setup
#   procedure is installing.  Don't specify if the setup procedure is not
#   installing a plugin.
#   See also 'plugins'.
#
# plugins: Set of Orthanc plugins
#
#   Optional.
#   Can't be used with 'plugin'.
#   Array of plugin names (see 'plugin').
#
# pluginselectors: List of plugin selector descriptors and their default status.
#
#   Optional.
#   Requires 'plugins'.
#   Each plugin selector descriptor is composed of a name and an optional
#   default status marker separated by a colon ':'.  They are mapped to each
#   plugin according to their order in the array, respective of the order of the
#   corresponding plugins in the 'plugins' array.
#
#   The name will be interpreted as an environment variable prefixed with the
#   setup procedure name and suffixed with _ENABLED.  These environment
#   variables allow the user to select individal plugins to explicitly enable or
#   disable within a setup procedure.
#
#   The default status marker must be "explicit" or nothing.  When a plugin
#   default status is set to "explicit", it won't be implicitly enabled when a
#   configuration file is available and must be explicitly enabled with an
#   environment variable.  It is only taken into account when a configuration
#   file is available (either generated or not).  Otherwise, the user must set
#   the value of the corresponding environment variable explicitly, or enable
#   all plugins with the setup procedure set wide ENABLED setting (i.e.
#   ${NAME}_ENABLED environment variable).  When the plugin is not marked as
#   explicit, the colon can be omitted.
#
#   Note: A plugin is implicitly a default plugin if no corresponding selector
#   is defined.
#
# conf: Orthanc configuration file
#
#   Optional.
#   Filename of the configuration (filename without path or extension) the
#   setup procedure is generating.
#
# default: Specify whether the bundle settings are used by default or not
#
#   Optional.
#   Requires 'conf' to be set.
#   If set to "true" and a configuration file is not already present in a
#   lower-level image layer, then generate the configuration file using the
#   default parameter values of the bundle (which may be different from the
#   defaults of Orthanc itself).  If one or more plugins are specified, they
#   are automatically enabled.  Can be overriden with the BUNDLE_DEFAULTS
#   setting.
#
# settings: List of environment variables used by the setup procedure set
#
#   Optional.
#   Names of environment variables, without the setup procedure set name
#   prefix.
#
#   Reserved settings: ENABLED, BUNDLE_DEFAULTS.
#
# globals: List of non-prefixed environment variables
#
#   Optional.
#   Names of global environment variables, i.e. special settings that will not
#   be prefixed with the setup procedure name.
#
#   Reserved globals: BUNDLE_DEBUG.
#
# secrets: Docker secrets
#
#   Optional.
#   List of settings that are secrets (keys, passwords, etc) to be retrieved
#   first from environment variables (as usual) then (preferrably) from Docker
#   secrets.  The Docker secret file names can be specified with the
#   ${NAME}_${SETTING}_SECRET environment variable and will default to
#   ${NAME}_${SETTING}.
#
# deprecated: List of deprecated environment variables
#
#   Optional.
#   List of settings that are deprecated.
#
declare \
	name \
	default \
	plugin \
	plugins \
	pluginselectors \
	conf \
	settings \
	globals \
	secrets \
	deprecated


# Simple log output facility.  Can be used in setup procedures, but only after
# the mandatory 'name' parameter is set.
function log {
	echo -e "$name: $*" >&2
}

function warn {
	log "WARNING: $*"
}

function err {
	log "ERROR: $*"
}


# inarray: Utility function to check if an element is contained in an array.
function inarray {
	local needle=$1
	shift
	local element
	for element; do
		if [[ "$element" == "$needle" ]]; then
			return 0
		fi
	done
	return 1
}


# The setup procedure is executed in the same shell context (and thus same
# process) as the setup executor.
#
# Recall: One setup procedure executor process is run per setup procedure.
#
# shellcheck source=/dev/null
source "$1"


# Basic setup procedure validation

if [[ ! $name ]]; then
	exit 2
fi

if [[ $plugin ]] && ((${#plugins[@]})); then
	exit 6
elif [[ $plugin ]]; then
	plugins=("$plugin")
	unset plugin
fi


# getenv: Outputs the environment variable value for given setting.
#
# Note that each setting set via the environment for the setup procedure is
# prefixed with the abbreviated name of the setup procedure set.
#
function getenv {
	eval echo "\$${name}_$1"
}


# getglobal: Outputs the environment variable value for a given global setting
#
function getglobal {
	eval echo "\$$1"
}


# gensecret: Generate a variable for given secret setting.
#
# Will use the corresponding environment variable if available, but users are
# encouraged to use Docker secrets, which it will then use instead.  The
# filename of the secret can be set with the ${NAME}_${SETTING}_SECRET
# environment variable, and will default to the same name as the environment
# variable name of the setting (${NAME}_${SETTING}).
#
# The intent of this function is to be a pre-processor for setup procedure
# settings: the generated variable for the secret will have the same name as
# what the environment variable for the corresponding setting would have had
# if the user set it, even if the user only uses Docker secrets.
#
# Note: This variable is not exported to the environment and will thus remain
# contained to the setup executor process context before it is likely written
# out by the configuration generator of the setup procedure.  No secrets will
# be passed in child processes unless the user explicitly sets environment
# variables.
#
function gensecret {
	local setting=$1 value secret file
	value=$(getenv "$setting")
	if [[ $value ]]; then
		return
	fi
	secret=$(getenv "${setting}_SECRET")
	file=/run/secrets/${secret:-${name}_${setting}}
	if [[ -e $file ]]; then
		eval "${name}_${setting}=\$(<\"$file\")"
	fi
}


# processenv: Indicate whether user-settings are defined and process them.
#
# Returns 0 if at least one setting has been passed via the environment.
# Returns a non-zero value otherwise.
#
# The abbreviated setup procedure set name is stripped from each setting name
# for convenience.
#
function processenv {
	local ret=1 variable value
	for setting in "${settings[@]}"; do
		value=$(getenv "$setting")
		if [[ $value ]]; then
			eval "$setting=\$value"
			ret=0
			if inarray "$setting" "${deprecated[@]}"; then
				warn "$setting is deprecated"
			fi
		fi
	done
	for global in "${globals[@]}"; do
		value=$(getglobal "$global")
		if [[ $value ]]; then
			ret=0
			break
		fi
	done
	for selector in "${pluginselectors[@]}"; do
		variable=${selector%:*}_ENABLED
		value=$(getenv "$variable")
		if [[ $value ]]; then
			eval "$variable=\$value"
		fi
	done
	return $ret
}


# enableplugin: Enable plugin based on multiple conditions
#
# We only enable plugins if a configuration file is available (either provided
# by the user or auto-generated) and the plugin is not marked as an explicitly
# enabled plugin (in the "plugin selector" descriptor).
#
# This can be overridden (both to enable or disable) by explicitly setting the
# ${NAME}_ENABLED environment variable (implicit setting), and further
# overridden by setting the corresponding ${NAME}_${PLUGIN}_ENABLED environment
# variable ("plugin selector" value).
#
function enableplugin {
	local enabled i=$1 plugin selector selected allselected defplugin
	plugin=${plugins[$i]}
	selector=${pluginselectors[$i]}
	selected=$(getenv "${selector%:*}_ENABLED")
	allselected=$(getenv ENABLED)
	if [[ -e /usr/share/orthanc/plugins/$plugin.so ]]; then
		log "Plugin '$plugin' enabled"
		return
	fi
	# Notice: Implicitly a default plugin if no selector is defined.
	if [[ ! $selector =~ : || ${selector#*:} != explicit ]]; then
		defplugin=true
	fi
	if [[ $confavailable == true && $defplugin == true ]]; then
		enabled=true
	fi
	if [[ $allselected ]]; then
		enabled=$allselected
	fi
	if [[ $selected ]]; then
		enabled=$selected
	fi
	if [[ $enabled == true ]]; then
		log "Enabling plugin '$plugin'..."
		mv /usr/share/orthanc/plugins{-disabled,}/"$plugin".so
	fi
}


# Generate variables from Docker secrets if corresponding variables have not
# been passed via the environment already.
for secret in "${secrets[@]}"; do
	gensecret "$secret"
done


# If the user explicitly defines whether to use bundle defaults or not,
# respect that wish by overriding the setup procedure 'default' parameter.
usedefaults=$(getenv BUNDLE_DEFAULTS)
if [[ $usedefaults ]]; then
	default=$usedefaults
fi


# Set absolute path of target configuration file if specified.
if [[ $conf ]]; then
	conf=/etc/orthanc/$conf.json
fi


# Process environnment variables, determine if at least one is available.
if processenv; then
	settingsavailable=true
fi


# Optional configuration file generation.
if [[ -e $conf ]]; then
	log "'$conf' taking precendence over related env vars (file might have been generated from env vars during a previous run)"
	confavailable=true
else
	if [[ $settingsavailable == true || $default == true ]]; then
		if [[ ! $conf ]]; then
			exit 3
		fi
		if [[ $(type -t genconf) != function ]]; then
			exit 4
		fi
		log "Generating '$conf'..."
		if genconf "$conf" && ((${#plugins[@]})); then
			confavailable=true
		else
			warn "Not generating configuration file"
		fi
		if [[ $BUNDLE_DEBUG == true ]]; then
			cat "$conf" >&2
		fi
	fi
fi


# Optional plugin installation.
if ((${#plugins[@]})); then
	for i in "${!plugins[@]}"; do
		enableplugin "$i"
	done
fi