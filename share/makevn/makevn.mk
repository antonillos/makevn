MAKEVN_BIN ?= makevn
MAKEVN_REPO_ROOT ?= $(CURDIR)

.PHONY: vn-help vn-doctor vn-init vn-refresh vn-make-install vn-make-uninstall vn-uninstall vn-profile-refresh vn-compile vn-test-compile vn-compile-tests vn-validate vn-package vn-build vn-clean vn-test vn-verify-ut vn-verify-ut-coverage vn-verify-it vn-verify-it-coverage vn-verify vn-verify-changes vn-coverage vn-coverage-changes vn-pr-verify vn-mutation vn-docker-up vn-docker-down vn-docker-ps vn-docker-stats vn-docker-ps-required vn-karate-docker-up vn-karate-docker-down vn-karate-test vn-karate-all vn-run-app vn-run-app-bg vn-stop-app vn-run vn-jdk-current vn-jdk-list vn-exec

define makevn_run
	@set +e; \
	"$(MAKEVN_BIN)" --repo "$(MAKEVN_REPO_ROOT)" $(1); \
	rc=$$?; \
	if [ "$$rc" -eq 130 ]; then \
		exit 0; \
	fi; \
	exit "$$rc"
endef

vn-help:
	@printf '%s\n' 'makevn make targets:'
	@printf '%s\n' '  make vn-doctor'
	@printf '%s\n' '  make vn-init'
	@printf '%s\n' '  make vn-refresh'
	@printf '%s\n' '  make vn-make-install'
	@printf '%s\n' '  make vn-make-uninstall'
	@printf '%s\n' '  make vn-uninstall'
	@printf '%s\n' '  make vn-profile-refresh'
	@printf '%s\n' '  make vn-compile'
	@printf '%s\n' '  make vn-test-compile'
	@printf '%s\n' '  make vn-compile-tests'
	@printf '%s\n' '  make vn-validate'
	@printf '%s\n' '  make vn-package'
	@printf '%s\n' '  make vn-build'
	@printf '%s\n' '  make vn-clean'
	@printf '%s\n' '  make vn-test'
	@printf '%s\n' '  make vn-test NAME=UserRepositoryTest'
	@printf '%s\n' '  make vn-test NAMES="UserRepositoryTest,OrderRepositoryTest"'
	@printf '%s\n' '  make vn-test NAME=UserRepositoryTest FAST=true'
	@printf '%s\n' '  make vn-test MAKEVN_TEST_ARGS="--name UserRepositoryTest"'
	@printf '%s\n' '  make vn-verify-ut'
	@printf '%s\n' '  make vn-verify-ut-coverage'
	@printf '%s\n' '  make vn-verify-it'
	@printf '%s\n' '  make vn-verify-it-coverage'
	@printf '%s\n' '  make vn-verify'
	@printf '%s\n' '  make vn-verify-changes'
	@printf '%s\n' '  make vn-coverage'
	@printf '%s\n' '  make vn-coverage-changes'
	@printf '%s\n' '  make vn-pr-verify'
	@printf '%s\n' '  make vn-mutation'
	@printf '%s\n' '  make vn-mutation VERBOSE=true'
	@printf '%s\n' '  make vn-docker-up'
	@printf '%s\n' '  make vn-docker-down'
	@printf '%s\n' '  make vn-docker-ps'
	@printf '%s\n' '  make vn-docker-stats'
	@printf '%s\n' '  make vn-docker-ps-required'
	@printf '%s\n' '  make vn-docker-ps-required MAKEVN_DOCKER_PS_REQUIRED_ARGS="--compose karate"'
	@printf '%s\n' '  make vn-karate-docker-up'
	@printf '%s\n' '  make vn-karate-docker-down'
	@printf '%s\n' '  make vn-karate-test'
	@printf '%s\n' '  make vn-karate-test TAG=@smoke'
	@printf '%s\n' '  make vn-karate-all'
	@printf '%s\n' '  make vn-run-app'
	@printf '%s\n' '  make vn-run-app-bg'
	@printf '%s\n' '  make vn-stop-app'
	@printf '%s\n' '  make vn-run'
	@printf '%s\n' '  make vn-jdk-current'
	@printf '%s\n' '  make vn-jdk-list'
	@printf '%s\n' '  make vn-exec MAKEVN_ARGS="-- mvn -v"'

vn-doctor:
	$(call makevn_run,doctor)

vn-init:
	$(call makevn_run,init $(MAKEVN_INIT_ARGS))

vn-refresh:
	$(call makevn_run,refresh $(MAKEVN_REFRESH_ARGS))

vn-make-install:
	$(call makevn_run,make install $(MAKEVN_MAKE_INSTALL_ARGS))

vn-make-uninstall:
	$(call makevn_run,make uninstall $(MAKEVN_MAKE_UNINSTALL_ARGS))

vn-uninstall:
	$(call makevn_run,uninstall $(MAKEVN_UNINSTALL_ARGS))

vn-profile-refresh:
	$(call makevn_run,profile refresh)

vn-compile:
	$(call makevn_run,compile $(MAKEVN_COMPILE_ARGS))

vn-test-compile:
	$(call makevn_run,test-compile $(MAKEVN_TEST_COMPILE_ARGS))

vn-compile-tests:
	$(call makevn_run,compile-tests $(MAKEVN_COMPILE_TESTS_ARGS))

vn-validate:
	$(call makevn_run,validate $(MAKEVN_VALIDATE_ARGS))

vn-package:
	$(call makevn_run,package $(MAKEVN_PACKAGE_ARGS))

vn-build:
	$(call makevn_run,build $(MAKEVN_BUILD_ARGS))

vn-clean:
	$(call makevn_run,clean $(MAKEVN_CLEAN_ARGS))

vn-test:
	@set +e; \
	args="$(MAKEVN_TEST_ARGS)"; \
	if [ -n "$(strip $(NAME))" ]; then \
		args="$$args --name $(NAME)"; \
	fi; \
	if [ -n "$(strip $(NAMES))" ]; then \
		args="$$args --name $(NAMES)"; \
	fi; \
	case "$(FAST)" in \
		1|true|TRUE|yes|YES) args="$$args --fast" ;; \
	esac; \
	"$(MAKEVN_BIN)" --repo "$(MAKEVN_REPO_ROOT)" test $$args; \
	rc=$$?; \
	if [ "$$rc" -eq 130 ]; then \
		exit 0; \
	fi; \
	exit "$$rc"

vn-verify-ut:
	@set +e; \
	args="$(MAKEVN_VERIFY_UT_ARGS)"; \
	"$(MAKEVN_BIN)" --repo "$(MAKEVN_REPO_ROOT)" verify-ut $$args; \
	rc=$$?; \
	if [ "$$rc" -eq 130 ]; then \
		exit 0; \
	fi; \
	exit "$$rc"

vn-verify-ut-coverage:
	@set +e; \
	args="$(MAKEVN_VERIFY_UT_COVERAGE_ARGS)"; \
	"$(MAKEVN_BIN)" --repo "$(MAKEVN_REPO_ROOT)" verify-ut-coverage $$args; \
	rc=$$?; \
	if [ "$$rc" -eq 130 ]; then \
		exit 0; \
	fi; \
	exit "$$rc"

vn-verify-it:
	@set +e; \
	args="$(MAKEVN_VERIFY_IT_ARGS)"; \
	"$(MAKEVN_BIN)" --repo "$(MAKEVN_REPO_ROOT)" verify-it $$args; \
	rc=$$?; \
	if [ "$$rc" -eq 130 ]; then \
		exit 0; \
	fi; \
	exit "$$rc"

vn-verify-it-coverage:
	@set +e; \
	args="$(MAKEVN_VERIFY_IT_COVERAGE_ARGS)"; \
	"$(MAKEVN_BIN)" --repo "$(MAKEVN_REPO_ROOT)" verify-it-coverage $$args; \
	rc=$$?; \
	if [ "$$rc" -eq 130 ]; then \
		exit 0; \
	fi; \
	exit "$$rc"

vn-verify:
	@set +e; \
	args="$(MAKEVN_VERIFY_ARGS)"; \
	"$(MAKEVN_BIN)" --repo "$(MAKEVN_REPO_ROOT)" verify $$args; \
	rc=$$?; \
	if [ "$$rc" -eq 130 ]; then \
		exit 0; \
	fi; \
	exit "$$rc"

vn-verify-changes:
	@set +e; \
	args="$(MAKEVN_VERIFY_CHANGES_ARGS)"; \
	"$(MAKEVN_BIN)" --repo "$(MAKEVN_REPO_ROOT)" verify-changes $$args; \
	rc=$$?; \
	if [ "$$rc" -eq 130 ]; then \
		exit 0; \
	fi; \
	exit "$$rc"

vn-coverage:
	$(call makevn_run,coverage $(MAKEVN_COVERAGE_ARGS))

vn-coverage-changes:
	$(call makevn_run,coverage-changes $(MAKEVN_COVERAGE_CHANGES_ARGS))

vn-pr-verify:
	$(call makevn_run,pr-verify $(MAKEVN_PR_VERIFY_ARGS))

vn-mutation:
	@set +e; \
	args="$(MAKEVN_MUTATION_ARGS)"; \
	if [ -n "$(strip $(MODULE))" ]; then \
		args="$$args --module $(MODULE)"; \
	fi; \
	case "$(VERBOSE)" in \
		1|true|TRUE|yes|YES) args="$$args --verbose" ;; \
	esac; \
	"$(MAKEVN_BIN)" --repo "$(MAKEVN_REPO_ROOT)" mutation $$args; \
	rc=$$?; \
	if [ "$$rc" -eq 130 ]; then \
		exit 0; \
	fi; \
	exit "$$rc"

vn-docker-up:
	$(call makevn_run,docker-up)

vn-docker-down:
	$(call makevn_run,docker-down)

vn-docker-ps:
	$(call makevn_run,docker-ps)

vn-docker-stats:
	$(call makevn_run,docker-stats)

vn-docker-ps-required:
	$(call makevn_run,docker-ps-required $(MAKEVN_DOCKER_PS_REQUIRED_ARGS))

vn-karate-docker-up:
	$(call makevn_run,karate-docker-up)

vn-karate-docker-down:
	$(call makevn_run,karate-docker-down)

vn-karate-test:
	@set +e; \
	args="$(MAKEVN_KARATE_TEST_ARGS)"; \
	if [ -n "$(strip $(TAG))" ]; then \
		args="$$args --tag $(TAG)"; \
	fi; \
	"$(MAKEVN_BIN)" --repo "$(MAKEVN_REPO_ROOT)" karate-test $$args; \
	rc=$$?; \
	if [ "$$rc" -eq 130 ]; then \
		exit 0; \
	fi; \
	exit "$$rc"

vn-karate-all:
	@set +e; \
	args="$(MAKEVN_KARATE_ALL_ARGS)"; \
	if [ -n "$(strip $(TAG))" ]; then \
		args="$$args --tag $(TAG)"; \
	fi; \
	"$(MAKEVN_BIN)" --repo "$(MAKEVN_REPO_ROOT)" karate-all $$args; \
	rc=$$?; \
	if [ "$$rc" -eq 130 ]; then \
		exit 0; \
	fi; \
	exit "$$rc"

vn-run-app:
	$(call makevn_run,run-app)

vn-run-app-bg:
	$(call makevn_run,run-app-bg)

vn-stop-app:
	$(call makevn_run,stop-app)

vn-run:
	$(call makevn_run,run)

vn-jdk-current:
	$(call makevn_run,jdk current)

vn-jdk-list:
	$(call makevn_run,jdk list)

vn-exec:
	@test -n "$(strip $(MAKEVN_ARGS))" || { printf '%s\n' 'Usage: make vn-exec MAKEVN_ARGS="-- mvn -v"'; exit 1; }
	$(call makevn_run,exec $(MAKEVN_ARGS))
