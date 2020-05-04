#!/usr/bin/env bash

#TODO Probably awk or perl can be used in a lot of places
set -euo pipefail
IFS=$'\n\t'


jdeps="jdeps"

if ! hash ${jdeps} 2>/dev/null; then
  echo "No jdeps found - is it installed and on your PATH?"; exit 1
fi

fastutil_regex='it\.unimi\.dsi\.fastutil\..*'

function check_exec()  {
  for exec in $@; do
    if ! hash "$exec"; then
      echo "$exec not found"; exit 1
    fi
  done
}

function print_synopsis() {
  >&2
  #    |                                                                               |
  echo "Synopsis: \"$(basename $0) <command> <args>\", where command is"
  echo "  - \"find\" (searches for usages of fastutil in your project) or"
  echo "  - \"minimize\" (creates a jar containing transitive dependencies of fastutil)"
  echo ""
  echo "Arguments:"
  echo " find:"
  echo "   <paths to analyse> - Analyses the given path (jar or directory for usages"
  echo "       of fastutil classes"
  echo "   --cp <path> - Adds the given path (jar or directory) to the searched class-"
  echo "       path. This is useful if you have a big library making use of a lot of"
  echo "       fastutil, but you only use a small subset of that library. Make sure"
  echo "       not to include fastutil itself here!"
  echo "   --src - Output paths to the .java files"
  echo "   --cls - Output paths to the .class files"
  echo " minimize: <path to fastutil.jar> <path to class list>"
}

function print_usage() {
  >&2
  #    |                                                                               |
  echo "Usage: Typically, you want to first create the list of fastutil dependencies by"
  echo "running this script with \"find\" on your project classes and write this"
  echo "dependency list into a file:"
  echo ""
  echo "  $(basename $0) find path-to-project > dependencies.txt"
  echo ""
  echo "Then call \"minimize\" onto the matching fastutil jar to create a compact"
  echo "version, containing only the necessary classes:"
  echo ""
  echo "  $(basename $0) minimize fastutil.jar dependencies.txt"
  echo ""
  echo "A more advanced usage would be to build a minimized jar based on manually"
  echo "written \"dependencies.txt\" which can be directly passed to \"minimize\"."
}

function invalid_argument() {
  print_synopsis
  exit 1
}

[ ${#} -ge 1 ] || invalid_argument
command="$1"

case "$command" in
  "find")
  shift

  output_mode="class"
  declare -a class_paths=()
  declare -a analyse_paths=()

  while [ ${#} -gt 0 ]; do
    case "$1" in
      "--classpath"|"--cp")
        [ ${#} -ge 1 ] || invalid_argument
        class_paths+=("$2")
        shift
      ;;
      "--source"|"--src")
         output_mode="source"
      ;;
      "--class"|"--cls")
         output_mode="class"
      ;;
      *)
        analyse_paths+=("$1")
    esac
    shift
  done

  [ ${#analyse_paths[@]} -ge 1 ] || invalid_argument

  for path in "${class_paths[@]+"${class_paths[@]}"}" "${analyse_paths[@]}"; do
    if [ ! -e "$path" ]; then
      >&2 echo "Path \"$path\" does not exist"; exit 1
    fi
    case "$path" in
      *"fastutil"*)
        >&2 echo "Path $path looks like a fastutil jar - you probably don't want to include this" ;;
    esac
  done

  if [ $(find "${analyse_paths[@]}" -name "*.class" | wc -l) -eq 0 ]; then
    echo "No *.class files found in any of the specified paths"; exit 1
  fi

  if [ ${#class_paths[@]} -gt 0 ]; then
    function join_by { local IFS="$1"; shift; echo "$*"; }
    declare -a classpath_argument=("-cp" $(join_by ':' "${class_paths[@]}"))
  fi

  if ! dependencies=$(jdeps -recursive -verbose:class \
    "${classpath_argument[@]+"${classpath_argument[@]}"}" "${analyse_paths[@]}" |\
    awk '/it\.unimi\.dsi\.fastutil\..*not found$/ { print $2 }' | sort | uniq) \
    || [ -z "$dependencies" ]
  then
    >&2 echo "No unresolved references found - is fastutil on the classpath?"
    exit 1
  fi

  if [ "$output_mode" == "class" ]; then
    echo "$dependencies" | sed 's!\.!/!g' | sed 's!^\(.*\)$!\1.class!'
  else
    echo "$dependencies" | grep -v '\$' | sed 's!\.!/!g' | sed 's!^\(.*\)$!\1.java!'
  fi
  exit 0
  ;;

  "minimize")
  shift
  check_exec "zip" "unzip"

  [ ${#} -ge 2 ] || invalid_argument

  jar_path="$(realpath $1)"
  if [ ! -f "$jar_path" ]; then
    >&2 echo "No file at \"$jar_path\""
    exit 1
  fi

  class_list_path="$(realpath $2)"
  if [ ! -f "$class_list_path" ]; then
    >&2 echo "No file at \"$class_list_path\""
    exit 1
  fi

  dest_path="${jar_path%\.jar}-min.jar"
  if [ -e "$dest_path" ]; then
    >&2 echo "Destination path $dest_path exists"
    exit 1
  fi

  jar_name="$(basename ${dest_path})"

  tmp_dir=$(mktemp -d -t "fastutil-min.XXXX")
  trap "{ rm -rf \"${tmp_dir}\"; exit 255; }" EXIT

  ( >&2 echo "Resolving transitive dependencies" )

  class_paths=$(cat "$class_list_path" | grep '.class$')
  if [ -z "$class_paths" ]; then
    >&2 echo "No classes found in $class_list_path - make sure they are proper paths to .class files"
    exit 1
  fi

  class_list=${class_paths//.class/}
  class_list=${class_list//\//.}

  if ! transitive_dependencies=$(cd ${tmp_dir} && jdeps -recursive -regex "$fastutil_regex" \
    -verbose:class -cp "$jar_path" ${class_list} | awk '/      -> / { gsub(/\./, "/", $2) ".class"; print $2 ".class" }')\
    || [ -z "$transitive_dependencies" ]
  then
    >&2 echo "Could not resolve dependencies with $jar_path - probably not a complete fastutil jar."
    exit 1
  fi

  dependencies=( ${class_paths[@]} ${transitive_dependencies[@]} )
  ( >&2 echo "Unpacking jar from $jar_path" )
  if ! output=$(unzip -q "$jar_path" "META-INF/*" $(printf '%s\n' "${dependencies[@]}" | sort | uniq) -d "$tmp_dir" 2>&1); then
    >&2 echo "Error: $output"; exit 1
  fi

  ( >&2 echo "Creating minimized jar at $dest_path" )
  if ! output=$(cd "$tmp_dir" && zip -9 -q -r "$dest_path" "it" "META-INF" 2>&1); then
    >&2 echo "Error: $output"; exit 1
  fi
  ;;
  "-h"|"--help")
  print_synopsis
  >&2 echo ""
  print_usage
  ;;
  *)
  invalid_argument
  ;;
esac