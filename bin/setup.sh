#!/bin/bash

base_dir=$(cd $(dirname $0);cd ..;pwd)

# Version pins live in .env (git-ignored). Bootstrap it from the tracked
# .env.example on first run so .env stays the single source of truth for both
# compose.yaml and bin/render-fess-config.sh.
if [ ! -f ${base_dir}/.env ]; then
  echo "No .env found; creating one from .env.example..."
  cp ${base_dir}/.env.example ${base_dir}/.env
fi
# fess-script-groovy is no longer downloaded: the Groovy script engine is
# bundled in Fess core since 15.0.
# No Fess data store plugins are needed for this demo: the FAQ content is
# crawled over plain HTTP via a WebConfig (see bin/register-faq-crawl.sh),
# not through a data store connector like fess-ds-git (codesearch's Git crawl).
fess_plugins=""

# fess-themes branch to fetch the helpdesk static theme from.
# Override with FESS_THEMES_BRANCH=<branch> to test theme changes from another
# branch.
fess_themes_branch="${FESS_THEMES_BRANCH:-main}"

# fess-themes source repo. Defaults to the public GitHub repo; override with
# FESS_THEMES_REPO=/path/to/local/fess-themes to fetch from a local checkout.
fess_themes_repo="${FESS_THEMES_REPO:-https://github.com/codelibs/fess-themes.git}"

if [ $(uname -s) = "Linux" ] ; then
  echo "Changing an owner for directories..."
  sudo chown -R $(id -u)  ${base_dir}/data
fi

echo "Creating directories..."
mkdir -p ${base_dir}/data/fess/home/fess
mkdir -p ${base_dir}/data/fess/opt/fess
mkdir -p ${base_dir}/data/fess/var/lib/fess
mkdir -p ${base_dir}/data/fess/var/log/fess
mkdir -p ${base_dir}/data/fess/usr/share/fess/app/WEB-INF/plugin
mkdir -p ${base_dir}/data/opensearch/usr/share/opensearch/data
mkdir -p ${base_dir}/data/opensearch/usr/share/opensearch/config/dictionary
mkdir -p ${base_dir}/data/content

rm -f ${base_dir}/data/fess/usr/share/fess/app/WEB-INF/plugin/fess-*.jar

for fess_plugin in ${fess_plugins} ; do
  plugin_name=$(echo $fess_plugin | sed -e "s/:.*//")
  plugin_version=$(echo $fess_plugin | sed -e "s/.*://")
  plugin_file=${base_dir}/data/fess/usr/share/fess/app/WEB-INF/plugin/${plugin_name}-${plugin_version}.jar
  echo "Downloading ${plugin_name} version ${plugin_version}..."
  curl -s -o ${plugin_file} \
    https://repo1.maven.org/maven2/org/codelibs/fess/${plugin_name}/${plugin_version}/${plugin_name}-${plugin_version}.jar
done

# Fetch helpdesk static theme from fess-themes repo (clones ${fess_themes_branch}).
if [ ! -d ${base_dir}/data/fess/themes/helpdesk ]; then
  echo "Fetching helpdesk theme from fess-themes (branch: ${fess_themes_branch})..."
  mkdir -p ${base_dir}/data/fess/themes/helpdesk
  tmp_themes=$(mktemp -d)
  git clone --depth 1 --branch "${fess_themes_branch}" "${fess_themes_repo}" ${tmp_themes}
  bash ${tmp_themes}/scripts/package.sh helpdesk
  unzip ${tmp_themes}/dist/helpdesk-*.zip -d ${base_dir}/data/fess/themes/helpdesk
  rm -rf ${tmp_themes}
fi

if [ ! -f ${base_dir}/data/fess/opt/fess/system.properties ]; then
  cp ${base_dir}/data/fess/opt/fess/system.properties.template ${base_dir}/data/fess/opt/fess/system.properties
fi

echo "Generating fess_config.properties (base + faqsearch overlay)..."
bash ${base_dir}/bin/render-fess-config.sh

if [ $(uname -s) = "Linux" ] ; then
  echo "Changing an owner for directories..."
  sudo chown -R 1001 ${base_dir}/data/fess/home/fess
  sudo chown -R 1001 ${base_dir}/data/fess/opt/fess
  sudo chown -R 1001 ${base_dir}/data/fess/var/lib/fess
  sudo chown -R 1001 ${base_dir}/data/fess/var/log/fess
  sudo chown -R 1001 ${base_dir}/data/fess/usr/share/fess/app/WEB-INF/plugin
  sudo chown -R 1001 ${base_dir}/data/fess/themes
  sudo chown -R 1000 ${base_dir}/data/opensearch/usr/share/opensearch/data
  sudo chown -R 1000 ${base_dir}/data/opensearch/usr/share/opensearch/config/dictionary
fi
