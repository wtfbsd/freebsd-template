// Jenkinsfile — build this template and boot-test what it produced.
//
// Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
//
// Generic on purpose: a fork can run this pipeline on its own Jenkins.
// There is no organisation name, no real host name and no address in this
// file. VM handling goes through ci/vm.sh, which dispatches to a pluggable
// provider (ci/providers/bhyve.sh ships as the reference; a site points
// WTFBSD_VM_PROVIDER_PATH at its own script).
//
// Releases are published with a Jenkins secret text credential whose id is
// "wtfbsd-ai-token" (a fixed id convention, the value never lives in this
// repository). This pipeline does not read that credential: it only builds,
// boot-tests and archives.
//
// Stages: Validate -> Prepare -> Test -> Build -> Boot test -> Archive.

// The pipeline names the VMs it creates after the job and the build number,
// so that a build that dies hard still leaves a name behind for
// post { always } to destroy. The name helper is a shell function, and
// tests/run-tests.sh extracts it from between the markers below and runs it,
// so that the test cannot drift from the text the pipeline uses.
def VM_NAME_FN = '''# vm-name-begin
# vm_build_name <prefix> - the raw name of a VM of this build: the job name
# with its folder and the build number. JOB_NAME is the full path of the job
# ("folder/job"); JOB_BASE_NAME is only the job itself, and that is not
# unique across the folders of a Jenkins.
vm_build_name() {
	printf '%s-%s-%s\n' "$1" "${JOB_NAME:-job}" "${BUILD_NUMBER:-0}"
}
# vm_name <raw> - print a VM name that matches the provider name rules
# (^[a-z][a-z0-9-]{0,30}$): lower case, a dash for everything else, and at
# most 31 characters. The name ends with a six-hex checksum of the full raw
# name: two jobs whose names sanitise to the same string, and two long names
# that are shortened to the same head, must never share a VM name.
vm_name() {
	_raw=$1
	_hash=$(printf '%s' "$_raw" | cksum | awk '{printf "%06x", $1 % 16777216}')
	_san=$(printf '%s' "$_raw" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz' |
		tr -c 'a-z0-9-' '-' | tr -s '-')
	while :; do
		case $_san in
		-*) _san=${_san#-} ;;
		*) break ;;
		esac
	done
	while :; do
		case $_san in
		*-) _san=${_san%-} ;;
		*) break ;;
		esac
	done
	case $_san in
	'' | *[!a-z0-9-]*) _san="vm" ;;
	esac
	case $_san in
	[a-z]*) : ;;
	*) _san="v$_san" ;;
	esac
	_len=${#_san}
	if [ "$_len" -gt 24 ]; then
		# the name is too long: its head and its tail are kept, and the
		# checksum of the raw name tells the two jobs apart
		_head=$(printf '%s' "$_san" | cut -c1-16)
		_tail=$(printf '%s' "$_san" | cut -c"$((_len - 6))"-)
		_san=$(printf '%s-%s' "$_head" "$_tail" | tr -s '-')
	fi
	printf '%s-%s\n' "$_san" "$_hash"
}
# vm-name-end
'''

// The paths of the build VM cross into the shell of that host: they are
// interpolated into the command that ssh(1) runs there. A path is therefore
// checked before it is used: it must be an absolute path of boring
// characters, so that nothing but a path can reach the remote shell.
//
// The helper is a shell function, and tests/run-tests.sh extracts it from
// between the markers below and runs it, so that the test cannot drift
// from the text the pipeline uses.
def REMOTE_PATH_FN = '''# remote-path-begin
# check_remote_path <value> <name> - refuse a value that is not an absolute
# path of boring characters. The rule is the pattern
# ^/[A-Za-z0-9._/-]+$: a value that matches it has no quote, no space and
# no shell metacharacter in it, so it cannot end the quoting it is put in.
check_remote_path() {
	_v=$1
	_n=$2
	case $_v in
	/) printf 'pipeline: %s must name a directory below /: %s\n' "$_n" "$_v" >&2; return 1 ;;
	/*) : ;;
	*)
		printf 'pipeline: %s must be an absolute path: %s\n' "$_n" "$_v" >&2
		return 1
		;;
	esac
	case $_v in
	*[!A-Za-z0-9._/-]*)
		printf 'pipeline: %s must match ^/[A-Za-z0-9._/-]+$: %s\n' "$_n" "$_v" >&2
		return 1
		;;
	esac
	return 0
}
# remote-path-end
'''

pipeline {
	// The parameter is empty on the first run of a fresh job, and the
	// label is checked by Jenkins when it allocates the agent - that
	// happens before any stage runs, so the fallback here is what keeps
	// a first run from failing on an empty label.
	agent { label "${params.AGENT_LABEL ?: 'bsd-builder'}" }

	parameters {
		choice(
			name: 'PROFILE',
			choices: ['desktop', 'appliance', 'both'],
			description: 'appliance = headless, serial console + sshd; desktop = X11 Xfce + LightDM; both = one image of each (build.sh -p)')
		string(
			name: 'AGENT_LABEL',
			defaultValue: 'bsd-builder',
			description: 'label of the Jenkins agent that builds and boot-tests')
		string(
			name: 'WTFBSD_VM_PROVIDER',
			defaultValue: 'bhyve',
			description: 'VM provider used by ci/vm.sh (ci/providers/<name>.sh)')
		choice(
			name: 'BUILD_ON_AGENT',
			choices: ['yes', 'no'],
			description: 'yes = build.sh runs directly on the agent; no = the build runs inside a VM made by ci/vm.sh')
		stashedFile(
			name: 'PRODUCT_CONF',
			description: 'product.conf to build (optional; without it the product-conf artifact is copied)')
		string(
			name: 'WTFBSD_VM_IMAGE',
			defaultValue: '',
			description: 'bootable image used when BUILD_ON_AGENT is no (a site provides its own FreeBSD build image)')
	}

	stages {
		stage('Validate') {
			steps {
				sh '''
					set -eu
					# the first build of a new job runs before Jenkins has
					# registered the parameters, so none of them is set: say
					# so instead of dying on an unset variable
					if [ -z "${PROFILE:-}" ]; then
						echo "the parameters of this job are not set (first build of a new job?): build again with parameters" >&2
						exit 1
					fi
					# API-triggered builds can bypass the choice lists
					case $PROFILE in
					desktop | appliance | both) ;;
					*) echo "PROFILE must be desktop, appliance or both" >&2; exit 1 ;;
					esac
					case $BUILD_ON_AGENT in
					yes | no) ;;
					*) echo "BUILD_ON_AGENT must be yes or no" >&2; exit 1 ;;
					esac
					case $WTFBSD_VM_PROVIDER in
					'') [ -n "${WTFBSD_VM_PROVIDER_PATH:-}" ] || { echo "set WTFBSD_VM_PROVIDER or WTFBSD_VM_PROVIDER_PATH" >&2; exit 1; } ;;
					*[!a-z0-9-]*) echo "WTFBSD_VM_PROVIDER must be a provider name (letters, digits and dashes only)" >&2; exit 1 ;;
					esac
					# AGENT_LABEL is not checked here: Jenkins checks the
					# label when it allocates the agent, which happens
					# before any stage of this pipeline runs. The agent
					# directive falls back to the default label when the
					# parameter is empty.
					'''
			}
		}

		stage('Prepare') {
			steps {
				script {
					sh '''
						# prepare-begin
						set -eu
						# the list of VMs this build creates starts empty: the
						# names of an earlier build belong to that build
						list="${WORKSPACE:-.}/.wtfbsd-vms"
						: > "$list"
						# the host keys of an earlier build are stale: the VMs of
						# this build are new, and a key that changed has to be
						# learned again
						hosts="${WORKSPACE:-.}/.wtfbsd-known-hosts"
						: > "$hosts"
						# prepare-end
					'''
					if (env.PRODUCT_CONF_FILENAME?.trim()) {
						// The File Parameter plugin does not hand a file
						// parameter to the workspace of a Pipeline
						// (JENKINS-27413). It stashes the file under the
						// name of the parameter, and unstash() puts it
						// into the workspace of the build under that
						// name.
						//
						// The plugin also sets NAME_FILENAME to the name
						// of the file that was uploaded, and leaves it
						// empty when the optional parameter was not
						// filled in: that is what says whether there is
						// a file to build with.
						// unverified: confirm with one real upload run
						unstash 'PRODUCT_CONF'
						sh '''
							# product-conf-begin
							set -eu
							cp PRODUCT_CONF product.conf
							test -s product.conf
							# product-conf-end
						'''
					} else {
						copyArtifacts(
							projectName: 'product-conf',
							filter: 'product.conf',
							optional: false)
					}
				}
			}
		}

		stage('Test') {
			steps {
				sh '''
					# the test suite runs before anything is built: a tree
					# that fails its own checks must not produce an image
					sh tests/run-tests.sh
				'''
			}
		}

		stage('Build') {
			steps {
				sh(script: VM_NAME_FN + REMOTE_PATH_FN + '''
					set -eu
					rm_out() { # rm_out <path> <guardroot> — only a non-empty path under the guard root
						[ -n "${1:-}" ] || { echo "refusing an empty path" >&2; exit 1; }
						[ -n "${2:-}" ] || { echo "refusing an empty guard root" >&2; exit 1; }
						[ "$1" != "$2" ] || { echo "refusing to remove $2" >&2; exit 1; }
						case $1 in "$2"/*) : ;; *) echo "refusing to remove $1: it is outside $2" >&2; exit 1 ;; esac
						[ -d "$1" ] || return 0
						rm -rf -- "$1"
					}
					rm_out "$PWD/out" "$PWD"
					case $BUILD_ON_AGENT in
					yes)
						./build.sh -c product.conf -p "$PROFILE"
						;;
					no)
						[ -n "$WTFBSD_VM_IMAGE" ] || { echo "WTFBSD_VM_IMAGE is required when BUILD_ON_AGENT is no" >&2; exit 1; }
						list="${WORKSPACE:-.}/.wtfbsd-vms"
						build_name=$(vm_name "$(vm_build_name build)")
						# the name goes into the list before the VM exists: a
						# build that dies here still leaves a name to destroy
						printf '%s\n' "$build_name" >> "$list"
						sh ci/vm.sh create "$build_name" "$WTFBSD_VM_IMAGE"
						addr=$(sh ci/vm.sh addr "$build_name")
						case $addr in
						'' | -* | *[!A-Za-z0-9._:@%-]*) echo "the VM address must be a host name or address (letters, digits, . _ : @ % - only)" >&2; exit 1 ;;
						esac
						# the build image carries an unmodified source tree and a checkout of this template
						build_dir=${WTFBSD_VM_BUILD_DIR:-/usr/local/src/freebsd-template}
						src=${WTFBSD_VM_SRC:-/usr/src}
						# both paths end up in the command that runs on the
						# build VM, where a shell reads them: they are
						# checked before they are used, so that a path
						# cannot carry anything but a path
						check_remote_path "$build_dir" WTFBSD_VM_BUILD_DIR || exit 1
						check_remote_path "$src" WTFBSD_VM_SRC || exit 1
						# the build runs unattended: no password prompt, and the
						# host key of the build VM is learned once and kept in
						# the workspace instead of being accepted blindly
						known_hosts="${WORKSPACE:-.}/.wtfbsd-known-hosts"
						# scp(1) needs an IPv6 address in brackets before
						# the colon of the path; ssh(1) takes it bare
						case $addr in
						*:*) raddr="[$addr]" ;;
						*) raddr=$addr ;;
						esac
						scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$known_hosts" product.conf "$raddr:$build_dir/product.conf"
						ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$known_hosts" "$addr" "cd '$build_dir' && ./build.sh -c product.conf -p $PROFILE -s '$src'"
						scp -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$known_hosts" -r "$raddr:$build_dir/out" .
						;;
					*) echo "BUILD_ON_AGENT must be yes or no" >&2; exit 1 ;;
					esac
					''')
			}
		}

		stage('Boot test') {
			steps {
				script {
					def profiles = params.PROFILE == 'both' ? ['appliance', 'desktop'] : [params.PROFILE]
					profiles.each { p ->
						def img = sh(script: "find out/${p} -maxdepth 1 -name '*.img' 2>/dev/null | head -1 || true", returnStdout: true).trim()
						if (!img) {
							error("no image was built for profile ${p}")
						}
						// the name of the VM goes into the list before the boot
						// test creates it, so that post { always } destroys it
						// even when the boot test is killed
						def boot = '''
							set -eu
							list="${WORKSPACE:-.}/.wtfbsd-vms"
							boot_name=$(vm_name "$(vm_build_name boot-@PROFILE@)")
							printf '%s\n' "$boot_name" >> "$list"
							sh tests/boot-test.sh "@IMAGE@" "@PROFILE@" "$boot_name"
						'''.replace('@IMAGE@', img).replace('@PROFILE@', p)
						sh(script: VM_NAME_FN + boot)
					}
				}
			}
		}

		stage('Archive') {
			steps {
				archiveArtifacts(
					artifacts: 'out/**/*.img,out/**/*.iso,out/SHA256',
					allowEmptyArchive: false)
			}
		}
	}

	post {
		always {
			// never leak a VM, even on failure. A destroy that failed is a
			// VM that may still be running: the names of those VMs are
			// collected, and the build is failed with them, so that a
			// leaked VM is never a green run.
			def leaked = sh(
				script: '''
					set -eu
					list="${WORKSPACE:-.}/.wtfbsd-vms"
					leaked=""
					if [ -f "$list" ]; then
						while IFS= read -r name; do
							[ -n "$name" ] || continue
							if ! sh ci/vm.sh destroy "$name"; then
								echo "could not destroy the VM $name" >&2
								leaked="$leaked $name"
							fi
						done < "$list"
					fi
					printf '%s\n' "$leaked"
				''',
				returnStdout: true).trim()
			if (leaked) {
				currentBuild.result = 'FAILURE'
				echo "these VMs may still be running:${leaked}"
			}
		}
	}
}
