# Sempere command index (`just` lists recipes). Works standalone and as a
# module of the dev/ workspace justfile.

set working-directory := '.'

# Build everything including tests
build:
    swift build --build-tests

# Run the whole test suite
test *ARGS:
    swift test {{ARGS}}

# Run tests the way Linux CI does (Docker on macOS)
test-linux *ARGS:
    scripts/test-linux.sh {{ARGS}}

# Fail on Apple-only imports under Sources/
portability:
    scripts/check-portability.sh

# Release build of the CLI
cli:
    swift build -c release --product sempere
    @echo ".build/release/sempere"

# Test the iPad app on the newest iPad simulator (needs Xcode)
app-test:
    scripts/app.sh test

# Build the app for Mac Catalyst, unsigned (needs Xcode)
app-catalyst:
    scripts/app.sh catalyst
