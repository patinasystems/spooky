#!/usr/bin/env nu

# Build the macOS Ghostty app using xcodebuild with a clean environment
# to avoid Nix shell interference (NIX_LDFLAGS, NIX_CFLAGS_COMPILE, etc.).

def main [
    --scheme: string = "Ghostty"       # Xcode scheme (Ghostty, DockTilePlugin)
    --configuration: string = "Debug"  # Build configuration (Debug, Release, ReleaseLocal)
    --action: string = "build"         # xcodebuild action (build, test, clean, etc.)
    --arch: string = ""                # Optional architecture for a native-only GhosttyKit build
    --xcconfig: string = ""            # Optional build settings file
    --only-testing: string = ""        # Optional target, suite, or test identifier
] {
    let project = ($env.FILE_PWD | path join "Ghostty.xcodeproj")
    let build_dir = ($env.FILE_PWD | path join "build")

    # Skip UI tests for CLI-based invocations because it requires
    # special permissions.
    let skip_testing = if $action == "test" {
        [-skip-testing GhosttyUITests]
    } else {
        []
    }

    let arch_args = if $arch == "" { [] } else { [-arch $arch] }
    let config_args = if $xcconfig == "" { [] } else { [-xcconfig ($xcconfig | path expand)] }
    let test_args = if $only_testing == "" { [] } else { [$"-only-testing:($only_testing)"] }

    (^env -i
        $"HOME=($env.HOME)"
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
        xcodebuild
        -project $project
        -scheme $scheme
        -configuration $configuration
        $"SYMROOT=($build_dir)"
        ...$arch_args
        ...$config_args
        ...$test_args
        ...$skip_testing
        $action)
}
