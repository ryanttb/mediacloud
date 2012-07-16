#!/bin/sh
set -u
set -o  errexit

working_dir=`dirname $0`
cd $working_dir

sudo ./install_scripts/install_mediacloud_deb_package_dependencies.sh
sudo ./install_scripts/create_default_db_user_and_databases.sh 
cp  mediawords.yml.dist mediawords.yml
sudo ./install_scripts/install_system_wide_modules_for_plpg_perl.sh
./install_mc_perlbrew_and_modules.sh

echo install complete 
echo running compile test
./script/run_carton.sh  exec -Ilib/ -- prove -r t/compile.t
echo compile test succeeded 
echo creating new database
./script/run_with_carton.sh ./script/mediawords_create_db.pl
