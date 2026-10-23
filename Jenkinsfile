// Jenkinsfile — stub pipeline: build this template inside a throwaway
// bhyve build VM on a fixed-size FreeBSD host.
//
// Copyright (c) 2026 The wtfbsd contributors. BSD-2-Clause (see LICENSE).
//
// Shape only: the real glue (checkout in the VM, builds, publication)
// lives in wtfbsd ci-templates. Releases there are published with the
// token stored as Jenkins credential "wtfbsd-ai-token"; this file never
// touches credentials, real IPs or real hostnames — the VM address comes
// from env.BUILD_VM_ADDR as a placeholder.

pipeline {
	agent { label 'bhyve' }

	parameters {
		choice(
			name: 'PROFILE',
			choices: ['desktop', 'appliance', 'both'],
			description: 'appliance = headless, serial console + sshd; desktop = X11 Xfce + LightDM; both = one image of each (build.sh -p)')
	}

	stages {
		stage('Prepare') {
			steps {
				// product.conf is produced by wtfbsd/agents
				// scripts/apply-answers.sh and published by the
				// product repo as an artifact. Job name is a stub.
				copyArtifacts(
					projectName: 'product-conf',
					filter: 'product.conf',
					optional: false)
			}
		}

		stage('Create VM') {
			steps {
				// template "freebsd-build" from ci-templates: 8 vCPU,
				// 16G RAM, 120G disk, vm-bhyve on the bhyve agent.
				sh '''
					vm create -t freebsd-build -c 8 -m 16G -s 120G "build-${BUILD_NUMBER}"
					vm start "build-${BUILD_NUMBER}"
					'''
			}
		}

		stage('Build') {
			steps {
				// BUILD_VM_ADDR is set by the ci-templates glue
				// (e.g. resolved from `vm list`); placeholder otherwise.
				sh '''
					addr="${BUILD_VM_ADDR:-build-vm-addr-placeholder}"
					case $addr in
					-* | *[!A-Za-z0-9._:@-]*)
						echo "BUILD_VM_ADDR must be a host name or address (letters, digits, . _ : @ - only)" >&2; exit 1 ;;
					esac
					# API-triggered builds can bypass the choice list
					case $PROFILE in
					desktop | appliance | both) ;;
					*) echo "PROFILE must be desktop, appliance or both" >&2; exit 1 ;;
					esac
					rm -rf -- ./out   # fixed relative path in this job workspace
					# PROFILE is exported from the job parameter; the VM is
					# expected to hold an unmodified /usr/src, pre-populated by the
					# ci-templates VM image (this stub does not clone src)
					scp product.conf "$addr:product.conf"
					ssh "$addr" "git clone https://github.com/wtfbsd/freebsd-template && cd freebsd-template && ./build.sh -c ../product.conf -p $PROFILE"
					scp -r "$addr:freebsd-template/out" .
					'''
			}
		}

		stage('Collect artifacts') {
			steps {
				archiveArtifacts(
					artifacts: 'out/**/*.img,out/**/*.iso,out/SHA256',
					allowEmptyArchive: false)
			}
		}
	}

	post {
		always {
			// never leak a build VM, even on failure
			sh 'vm destroy -f "build-${BUILD_NUMBER}" || true'
		}
	}
}
