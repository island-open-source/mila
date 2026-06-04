// Mila — sign + notarize pipeline (manual trigger).
//
// Builds Release Mila.app, signs with the Island Developer ID Application
// identity (cert imported into an ephemeral keychain by the shared library's
// mac.withAppleCerts), notarizes via notarytool, staples, and archives
// Mila-<version>.dmg as a Jenkins artifact.

def sharedLibraryRef = params.sharedLibraryRef?.trim() ?: 'stable'
library identifier: "shared-library@${sharedLibraryRef}", changelog: false

pipeline {
    agent { label 'mac-builder-m2-aws' }
    options {
        timeout(time: 90, unit: 'MINUTES')
    }
    parameters {
      string(name: 'gitRef', defaultValue: 'main',
             description: 'Git ref to build (branch, tag, or commit SHA).')
      booleanParam(name: 'skipNotarize', defaultValue: false,
             description: 'Sign only; skip the notarytool submit + staple step.')
      booleanParam(name: 'publishUpdate', defaultValue: true,
             description: 'After notarizing, publish to the Sparkle update channel (upload ZIP/DMG + appcast.xml to S3). Ignored when skipNotarize is true.')
      string(name: 'sharedLibraryRef', defaultValue: 'stable',
             description: 'Git ref for shared-library.')
    }
    stages {
      stage('Resolve version') {
        steps {
          script {
            env.MILA_VERSION = sh(
              script: '''awk -F'"' '/^[[:space:]]+MARKETING_VERSION:/ {print $2; exit}' project.yml''',
              returnStdout: true
            ).trim()
            if (!env.MILA_VERSION) {
              error "Could not extract MARKETING_VERSION from project.yml"
            }
            env.MILA_BUILD = sh(
              script: '''awk -F'"' '/^[[:space:]]+CURRENT_PROJECT_VERSION:/ {print $2; exit}' project.yml''',
              returnStdout: true
            ).trim()
            if (!env.MILA_BUILD) {
              error "Could not extract CURRENT_PROJECT_VERSION from project.yml"
            }
            echo "Building Mila v${env.MILA_VERSION} (build ${env.MILA_BUILD}) at ref ${params.gitRef}"
          }
        }
      }
      stage('Build Release') {
        steps {
          // bundle-diarization populates Mila/Resources/PythonRuntime/
          // (gitignored), which xcodebuild CpResource's into the .app.
          sh '''
            set -euo pipefail
            make bundle-diarization
            make project
            make release-build
          '''
        }
      }
      stage('Sign + Notarize') {
        steps {
          script {
            def macSecrets = globals.getMacSecrets()
            def coreConstants = globals.getCoreConstants()
            // withAppleCerts creates the ephemeral keychain, imports the cert
            // from Secrets Manager, exposes its path as $KEYCHAIN_PATH, and
            // tears it down on exit.
            mac.withAppleCerts(
                certs: [macSecrets.APPLE_DEVELOPER_632C133E22E032E716B3E03724F55137]) {
              withCredentials([usernamePassword(
                  credentialsId: globals.getSecrets().NOTARIZE_CREDENTIALS,
                  usernameVariable: 'NOTARIZE_USER',
                  passwordVariable: 'NOTARIZE_PASS')]) {
                withEnv([
                  "CODESIGN_IDENTITY=${coreConstants.ISLAND_DEVELOPER_ID_APPLICATION}",
                  "NOTARIZE_APPLE_ID=${NOTARIZE_USER}",
                  "NOTARIZE_APP_PASSWORD=${NOTARIZE_PASS}",
                  "NOTARIZE_TEAM_ID=${coreConstants.ISLAND_MAC_TEAM_ID}",
                  "OUTPUT_DIR=${env.WORKSPACE}",
                  "MILA_SKIP_NOTARIZE=${params.skipNotarize}"
                ]) {
                  sh '''
                    set -euo pipefail
                    APP_PATH="build-release/Build/Products/Release/Mila.app"
                    if [[ ! -d "$APP_PATH" ]]; then
                      echo "error: release build did not produce $APP_PATH" >&2
                      exit 1
                    fi
                    chmod +x scripts/sign-and-notarize.sh
                    SKIP_NOTARIZE="$MILA_SKIP_NOTARIZE" \
                      scripts/sign-and-notarize.sh "$APP_PATH" "$MILA_VERSION"
                  '''
                }
              }
            }
          }
        }
      }
      stage('Verify') {
        steps {
          sh '''
            set -euo pipefail
            DMG="${WORKSPACE}/Mila-${MILA_VERSION}.dmg"
            if [[ ! -f "$DMG" ]]; then
              echo "error: $DMG not produced" >&2
              exit 1
            fi
            MOUNT="$(mktemp -d)"
            hdiutil attach -nobrowse -mountpoint "$MOUNT" "$DMG"
            codesign -dvvv "${MOUNT}/Mila.app" 2>&1 | grep -E "Authority|TeamIdentifier|CDHash|Identifier=|Sealed" || true
            codesign -d -r- "${MOUNT}/Mila.app" 2>&1 | grep designated || true
            hdiutil detach "$MOUNT"
          '''
        }
      }
      stage('Publish Sparkle update') {
        // Only for real (notarized) releases. Uploads the EdDSA-signed update
        // ZIP + DMG and refreshes appcast.xml on the S3 update channel, using
        // the mac-builder agent's IAM grant for S3. The Sparkle private key
        // (whose public half ships in Mila) comes from the Jenkins credential.
        when { expression { params.publishUpdate && !params.skipNotarize } }
        steps {
          withCredentials([string(credentialsId: 'mila-sparkle-private-key',
                                  variable: 'SPARKLE_PRIVATE_KEY')]) {
            sh '''
              set -euo pipefail
              DMG="${WORKSPACE}/Mila-${MILA_VERSION}.dmg"
              SPARKLE_BIN="${WORKSPACE}/build-release/SourcePackages/artifacts/sparkle/Sparkle/bin"
              chmod +x scripts/publish-sparkle.sh
              OUTPUT_DIR="${WORKSPACE}" SPARKLE_BIN="$SPARKLE_BIN" scripts/publish-sparkle.sh "$DMG" "$MILA_VERSION" "$MILA_BUILD"
            '''
          }
        }
      }
    }
    post {
      // archive runs in `success`, cleanWs in `cleanup` — Jenkins runs
      // them in this order so the workspace isn't wiped before archive.
      success {
        archiveArtifacts artifacts: "Mila-*.dmg", fingerprint: true, onlyIfSuccessful: true
      }
      cleanup {
        cleanWs notFailBuild: true
      }
    }
}
