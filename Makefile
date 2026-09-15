.PHONY: checks build app run

checks:
	swift run StewardChecks

build:
	swift build --product ResourceSteward

app:
	./scripts/package-app.sh

run: app
	open dist/ResourceSteward.app
