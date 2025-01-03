#!/bin/bash

usage="Usage: $0 [script_name]"

if [ $# -gt 1 -o "$1" = "help" -o "$1" = "-help" -o "$1" = "--help" ]; then
  echo "${usage}"
  exit 1;
fi

base_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# enforce that base_dir is a full path
if [ ! $(printf %.1s "$base_dir") = "/" ]; then
  echo "base_dir must be a full path"
  exit 1;
fi

# Generate configuration files to run liquidsoap as daemon.

# Make it work from a symlink:
if readlink ${0} >/dev/null 2>&1; then
  ORIG_DIR="$(dirname ${0})"
  TARGET="$(readlink ${0})"
  FIRST_CHAR="$(echo ${TARGET} | head -c1)"
  if [ "${FIRST_CHAR}" = "/" ]; then
    LINK_DIR="$(dirname ${TARGET})"
  else
    LINK_DIR="$(dirname "${ORIG_DIR}/${TARGET}")"
  fi
else
  LINK_DIR="$(dirname ${0})"
fi

cd ${LINK_DIR}

script_name=$1
if [ -z "${script_name}" ]; then
  script_name=main
fi

script_dir=${base_dir}/script

if [ -f "${script_name}" ]; then
  main_script="${script_name}"
elif [ -f "${script_dir}/${script_name}" ]; then
  main_script="${script_dir}/${script_name}"
elif [ -f "${script_dir}/${script_name}.liq" ]; then
  main_script="${script_dir}/${script_name}.liq"
else
  echo "Couldn't find a script at ${script_name}, ${script_dir}/${script_name} or ${script_dir}/${script_name}.liq"
  exit 1
fi

script_name=$(basename ${script_name})
script_name=${script_name%.*}
run_script="${script_dir}/${script_name}-run.liq"
pid_dir="${base_dir}/pid"
log_dir="${base_dir}/log"
liquidsoap_binary="$(which liquidsoap)"

if [ -z "${liquidsoap_binary}" ]; then
    echo "Unable to find liquidsoap_binary in your path."
    exit 1
fi

if [ -z "${init_type}" ]; then
    init_type="systemd"
fi;

initd_target="/etc/init.d/${script_name}-liquidsoap-daemon"
launchd_target="${HOME}/Library/LaunchAgents/${script_name}.liquidsoap.daemon.plist"
systemd_target="/etc/systemd/system/${script_name}-liquidsoap.service"

if [ -z "${mode}" ]; then
    mode=install
fi

if [ "${mode}" = "remove" ]; then
    sudo rm /etc/logrotate.d/${script_name}-liquidsoap
    case "${init_type}" in
	systemd)
	    sudo systemctl disable ${script_name}-liquidsoap
	    sudo systemctl stop ${script_name}-liquidsoap
	    sudo rm "$systemd_target"
	    sudo systemctl daemon-reload
	    ;;
	launchd)
	    launchctl unload "${launchd_target}"
	    ;;
	initd)
	    sudo "${initd_target}" stop
	    sudo update-rc.d -f liquidsoap-daemon remove
	    ;;
    esac
    exit 0
fi

mkdir -p "${pid_dir}"
mkdir -p "${log_dir}"
mkdir -p "${script_dir}"

cat <<EOS > "${run_script}"
#!${liquidsoap_binary}

set("log.file",true)
set("log.file.path","${log_dir}/${script_name}-run.log")
EOS

if [ "${init_type}" != "launchd" ]; then
    cat <<EOS >> "${run_script}"
settings.init.daemon.set(true)
settings.init.daemon.change_user.set(true)
settings.init.daemon.change_user.group.set("${USER}")
settings.init.daemon.change_user.user.set("${USER}")
settings.init.daemon.pidfile.set(true)
settings.init.daemon.pidfile.path.set("${pid_dir}/${script_name}-run.pid")
settings.init.daemon.pidfile.perms.set(0o640)
EOS
fi

echo "%include \"${main_script}\"" >> "${run_script}"

if [ ! -f ${main_script} ]; then
  echo "Creating dummy file"
  echo "output.dummy(blank())" >> "${main_script}"
fi

cat "liquidsoap.${init_type}.in" | \
    sed -e "s#@script_name@#${script_name}#g" | \
    sed -e "s#@user@#${USER}#g" | \
    sed -e "s#@liquidsoap_binary@#${liquidsoap_binary}#g" | \
    sed -e "s#@base_dir@#${base_dir}#g" | \
    sed -e "s#@run_script@#${run_script}#g" | \
    sed -e "s#@pid_file@#${pid_dir}/${script_name}-run.pid#g" > "${script_name}-liquidsoap.${init_type}"

cat "liquidsoap.logrotate.in" | \
    sed -e "s#@user@#${USER}#g" | \
    sed -e "s#@base_dir@#${base_dir}#g" > "${script_name}-liquidsoap.logrotate"

case "${init_type}" in
    launchd)
	cp -f "${script_name}-liquidsoap.${init_type}" "${launchd_target}"
	;;
    initd)
	sudo cp -f "${script_name}-liquidsoap.${init_type}" "${initd_target}"
	sudo chmod +x "${initd_target}"
	sudo update-rc.d ${script_name}-liquidsoap-daemon defaults 
	;;
    systemd)
	sudo cp -f "${script_name}-liquidsoap.${init_type}" "${systemd_target}"
	sudo systemctl daemon-reload
esac

sudo cp -f "${script_name}-liquidsoap.logrotate" "/etc/logrotate.d/${script_name}-liquidsoap"
