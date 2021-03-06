#!/bin/bash
set -e

echo "Moving to $(dirname "$(readlink "$BASH_SOURCE")")"
cd "$(dirname "$(readlink "$BASH_SOURCE")")"

versions=( "$@" )
if [ ${#versions[@]} -eq 0 ]; then
	versions=( [0-9]*/ )
fi
versions=( "${versions[@]%/}" )

generated_warning() {
	cat <<-EOH
		#
		# NOTE: THIS DOCKERFILE IS GENERATED VIA "update.sh"
		#
		# PLEASE DO NOT EDIT IT DIRECTLY.
		#
	EOH
}

travisEnv=
for version in "${versions[@]}"; do

    url='https://download.pydio.com/pub/core/archives/'

	expr='
		(keys[] | select (startswith("'"$version"'"))) as $version |
		[ $version, (
			.[$version] |
			select (.filename | endswith(".tar.gz")) |
				"https://download.pydio.com/pub/archive/" + .filename
		)]
	'

	IFS=$'\n'
	possibles=( $(
		curl -fsSL "$url" \
			| grep pydio-core \
			| grep tar.gz \
			| sed \
				-e '/pydio-core-[0-9]*\.[0-9]*\.[0-9]*\./!d' \
				-e 's/.*<a href="pydio-core-\([0-9]*\.[0-9]*\.[0-9]*\)\.\([^\"]*\)">.*/\1 pydio-core-\1.\2/g' \
			| awk '
				BEGIN {print "{"}
				      {print "\""$1"\": {\"filename\": \""$2"\"},"}
				END   {print "\"\":{}}"}
			' \
			| jq --raw-output "$expr | @sh" \
			| sort -r
	) )
	unset IFS

	if [ "${#possibles[@]}" -eq 0 ]; then
		echo >&2
		echo >&2 "error: unable to determine available releases of $version"
		echo >&2
		exit 1
	fi

	# format of "possibles" array entries is "VERSION URL.TAR.XZ URL.TAR.XZ.ASC SHA256 MD5" (each value shell quoted)
	#   see the "apiJqExpr" values above for more details
	eval "possi=( ${possibles[0]} )"
	fullVersion="${possi[0]}"
	url="${possi[1]}"

	echo "Treating $fullVersion with url $url"

	dockerfiles=()

	for target in \
		apache \
		fpm fpm/alpine \
        cli cli/alpine \
		zts zts/alpine \
	; do

		[ -d "$version/$target" ] || continue

		variant="${target%%/*}"

		echo "Generating $version/$target/Dockerfile from Dockerfile.template + $variant/Dockerfile-block-*"

		{ generated_warning; cat Dockerfile.template; } \
		| sed \
			-e "s/%%VARIANT%%/$variant/g" \
		| awk '
			$1 == "##</autogenerated>##" { ia = 0 }
			!ia { print }
			$1 == "##<autogenerated>##" { ia = 1; ab++; ac = 0 }
			ia { ac++ }
			ia && ac == 1 { system("cat '$variant'/Dockerfile-block-" ab) }
		' > "$version/$target/Dockerfile"

		for f in `find $variant -name "*.conf" -o -name "*.sh"`; do
			cp $f $version/$target/
		done

		dockerfiles+=( "$version/$target/Dockerfile" )
	done

	(
		set -x

		sed \
			-e 's/%%VERSION%%/'"$fullVersion"'/;' \
			-i '' "${dockerfiles[@]}"
	)

	newTravisEnv=
	for dockerfile in "${dockerfiles[@]}"; do

		echo "Treating docker file $dockerfile"

		dir="${dockerfile%Dockerfile}"
		dir="${dir%/}"
		variant="${dir#$version}"
		variant="${variant#/}"
		newTravisEnv+='\n  - VERSION='"$version VARIANT=$variant"
	done
	travisEnv="$newTravisEnv$travisEnv"

done

awk=$(which gawk || which awk)
travis="$($awk 'BEGIN {RS ="\n\n"} $1 == "env:" {$0 = "env:'"$travisEnv"'" } { printf "%s%s", $0, RS }' .travis.yml)"
echo "$travis" > .travis.yml
