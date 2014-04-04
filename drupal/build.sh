#!/bin/bash

###############################################################################
#
# DO NOT MODIFY THIS FILE
#
# Use the file $conf_file to override default settings
# and the $post_make file to run manual patches etc. after drush make
#
###############################################################################

base=$(cd "$(dirname "$0")"; pwd) # Base path
site_name="site" # Make file name without .make
site_profile="site" # Site install profile in code/profiles
config_file="$base/conf/config.sh" # configuration 
post_make="$base/conf/prepare.sh" # post make

store_old_builds=false
builds_to_keep=4

# Grab last paramater as the command
for command in $@; do :; done

drush=$(which drush 2> /dev/null) # Drush command file
drush_make_script="$base/conf/site.make" # Make script
builds_dir="$base" # Directory where we build sites
build_dir="$builds_dir/current" # Active current build dir
temp_build_dir="$builds_dir/build_new" # Active current build dir
old_builds_dir="$builds_dir/builds" # Directory for old builds
files_dir="$builds_dir/files" # Files directory for symbolic linking
drush_params="" # Drush parameters that are always passed
link_command="ln -s"

# Source directories
code_modules_dir=$base/code/modules
code_libraries_dir=$base/code/libraries
code_themes_dir=$base/code/themes
code_profiles_dir=$base/code/profiles

# Drupal internal paths for modules, themes and profiles
modules_path=sites/all/modules
libraries_path=sites/all/libraries
themes_path=sites/all/themes
profiles_path=profiles
files_path=sites/default/files

settings_directory="$base/conf"
settings_file=sites/default/settings.php

# Print a notification message
notice() {
	echo -e "\e[1;33m** BUILD NOTICE: $1\e[00m"
}

# Print error and exit
error() {
	echo -e "\e[1;31m** BUILD ERROR: $1\e[00m"
	exit -1
}

if [ -z "$drush" ]; then
	error "Drush seems to be missing."
fi

if [ -z "$WKV_SITE_ENV" ]; then
	error "You need to define WKV_SITE_ENV before using build.sh"
fi

if [ -e $config_file ]; then
	# Include site specific overrides for the settings
	source $config_file
else
	error "This project does not yet have $config_file. Please set it up."
fi

while [ $# -gt 0 ]
do
	case "$1" in
	-p|--production )
		link_command="cp -r"
		notice "Production build!"
		;;
	-b|--backup )
		store_old_builds=true
		notice "Will backup previous build!"
		;;
	esac
	shift
done


###############################################################################
# Functions

# Post make setup
post_make() {

	# Ensure directories exist
	mkdir -p $temp_build_dir/$modules_path
	mkdir -p $temp_build_dir/$libraries_path
	mkdir -p $temp_build_dir/$themes_path

	# Link code directories
	for file in $code_modules_dir/*
	do
		name=${file##*/}
		if [ -d $file -a ! -d $temp_build_dir/$modules_path/$name ]; then
			$link_command $file $temp_build_dir/$modules_path/$name
		fi		
	done
	# Link lib directories
	for file in $code_libraries_dir/*
	do
		name=${file##*/}
		if [ -d $file -a ! -d $temp_build_dir/$libraries_path/$name ]; then
			$link_command $file $temp_build_dir/$libraries_path/$name
		fi		
	done
	# Link theme directories
	for file in $code_themes_dir/*
	do
		name=${file##*/}
		if [ -d $file -a ! -d $temp_build_dir/$themes_path/$name ]; then
			$link_command $file $temp_build_dir/$themes_path/$name
		fi		
	done
	# Link theme directories
	for file in $code_profiles_dir/*
	do
		name=${file##*/}
		if [ -d $file -a ! -d $temp_build_dir/$profiles_path/$name ]; then
			$link_command $file $temp_build_dir/$profiles_path/$name
		fi		
	done
	if [ -d $files_dir ]; then
		ln -s $files_dir $temp_build_dir/$files_path
	fi

	# Prep settings.php
	echo "<?php
// ** DO NOT EDIT ** THIS FILE IS AUTOMATICALLY GENERATED BY THE BUILD PROCESS" >> $temp_build_dir/$settings_file

	if [ -e $settings_directory/$WKV_SITE_ENV.settings.php ]
	then
		echo "
include '$settings_directory/$WKV_SITE_ENV.settings.php';" >> $temp_build_dir/$settings_file
	else
		notice "No local settings.php file defined: TIP! You can create one at $settings_directory/$WKV_SITE_ENV.settings.php"
	fi

  echo "include '$settings_directory/global.settings.php';" >> $temp_build_dir/$settings_file
	# post make script
	if [ -e $post_make ]
	then
		notice "Post make script..."
		$post_make $base $temp_build_dir
	fi
}

# Requirements checking
check_requirements() {

	local error=false
	local dirs=(
		"$drush_make_script"
	)
	for dir in ${dirs[@]}
	do
		if [ ! -e $dir ]
		then
			echo "$dir does not exist"
			error=true
		fi
	done

	local commands=(
		"drush"
		"git"
		"curl"
		"unzip"
	)

	for cmd in ${commands[@]}
	do
		hash $cmd 2>&- || { echo >&2 "The command $cmd seems to be missing or inaccessible"; error=true; }
	done

	if [ $error == true ]
	then
		error "Please fix the problems and try again"
	fi

	# Ensure the build directories exists
	mkdir -p $old_builds_dir
	mkdir -p $files_dir
}

# Make a fresh build
make_build() {

	notice "Building..."

	$drush $drush_params --root=$temp_build_dir -y --translations=fi make $drush_make_script $temp_build_dir

	rc=$?
	if [[ $rc != 0 ]]
	then
		error "There seems to be a problem in your drush make file."
	fi

	# Store old build dir
	if $store_old_builds
	then
		# Store old build dir if it exists
		if [ -e $build_dir ]
		then
			build_time=`date -r $build_dir +"%Y-%m-%d-%H%M%S"`
			mv $build_dir $old_builds_dir/$build_time
		fi
	else
		# Remove old build dir
		rm -rf $build_dir
	fi

	post_make

	# Replace old build with new one
	mv $temp_build_dir $build_dir

	# Run cleanup
	remove_old_builds
}

# Purge the current build
purge_build() {
	if [ -d $current_build_dir ]; then
		notice "Purging..."
		$drush $drush_params --root=$build_dir -y sql-dump > $build_dir/dump.sql
		# We dont need any of this so redirect to null
		$drush $drush_params --root=$build_dir -y sql-drop &> /dev/null
	fi
}

# Clean up builds directory
remove_old_builds() {
	notice "Removing old builds..."
    files=($(find $old_builds_dir -mindepth 1 -maxdepth 1 -type d|sort -r))
    for (( i = 0 ; i < ${#files[@]} ; i++ )) do
        if [ $i -gt $builds_to_keep ]; then
        	rm -rf ${files[$i]}
        fi
    done
}

# Update the current build
update_build() {
	notice "Updating..."
	$drush $drush_params --root=$build_dir updatedb --y
	$drush $drush_params --root=$build_dir cc all
}

# Print help
usage() {
	echo "usage $0 [-p|--production,-b|--backup] <command>"
	echo ""
	echo "Where command is one of:"
	echo "  new     Create a new fresh build ready for installation"
	echo "  update  Update current build"
	echo "  purge   Clean up the current build"
	echo "  clean   Remove old builds ($builds_to_keep builds kept)"
	echo ""
	echo "Options:"
	echo "  -p, --production"
	echo "     Build by using copy instead of symlink. This is useful"
	echo "     when deploying to production."
	echo ""
	echo "  -b, --backup"
	echo "     Backup previous build."
}

control_c() {
	echo ""
	notice "Cancelled - Previous build remains intact"
	# if prev build dir exists
	# remove 
	exit 1
}

trap control_c SIGINT

###############################################################################
# MAIN SCRIPT START

check_requirements


case $command in
	new )
		if [ -e $build_dir ]
		then
			purge_build
		fi
		make_build
	;;
	clean )
		remove_old_builds
	;;
	purge )
		if [ ! -e $build_dir ]
		then
			error "There is no current build to purge!"
		fi
		purge_build
	;;
	update )
		if [ ! -e $build_dir ]
		then
			error "There is no current build to update!"
		fi
		make_build
		update_build
	;;
	* )
		usage
	;;
esac
