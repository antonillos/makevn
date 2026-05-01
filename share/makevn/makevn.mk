MAKEVN_BIN ?= makevn
MAKEVN_REPO_ROOT ?= $(CURDIR)

.PHONY: vn-help vn-doctor vn-init vn-uninstall vn-profile-refresh vn-compile vn-compile-tests vn-validate vn-package vn-build vn-clean vn-test vn-verify-ut vn-verify-ut-coverage vn-verify-it vn-verify-it-coverage vn-verify vn-verify-changes vn-pr-verify vn-docker-up vn-docker-down vn-docker-ps vn-run vn-jdk-current vn-jdk-list vn-exec

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
	@printf '%s\n' '  make vn-init MAKEVN_INIT_ARGS="--mode make-include"'
	@printf '%s\n' '  make vn-uninstall'
	@printf '%s\n' '  make vn-profile-refresh'
	@printf '%s\n' '  make vn-compile'
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
	@printf '%s\n' '  make vn-pr-verify'
	@printf '%s\n' '  make vn-docker-up'
	@printf '%s\n' '  make vn-docker-down'
	@printf '%s\n' '  make vn-docker-ps'
	@printf '%s\n' '  make vn-run'
	@printf '%s\n' '  make vn-jdk-current'
	@printf '%s\n' '  make vn-jdk-list'
	@printf '%s\n' '  make vn-exec MAKEVN_ARGS="-- mvn -v"'

vn-doctor:
	$(call makevn_run,doctor)

vn-init:
	$(call makevn_run,init $(MAKEVN_INIT_ARGS))

vn-uninstall:
	$(call makevn_run,uninstall $(MAKEVN_UNINSTALL_ARGS))

vn-profile-refresh:
	$(call makevn_run,profile refresh)

vn-compile:
	$(call makevn_run,compile $(MAKEVN_COMPILE_ARGS))

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
	$(call makevn_run,verify-ut $(MAKEVN_VERIFY_UT_ARGS))

vn-verify-ut-coverage:
	$(call makevn_run,verify-ut-coverage $(MAKEVN_VERIFY_UT_COVERAGE_ARGS))

vn-verify-it:
	$(call makevn_run,verify-it $(MAKEVN_VERIFY_IT_ARGS))

vn-verify-it-coverage:
	$(call makevn_run,verify-it-coverage $(MAKEVN_VERIFY_IT_COVERAGE_ARGS))

vn-verify:
	$(call makevn_run,verify $(MAKEVN_VERIFY_ARGS))

vn-verify-changes:
	$(call makevn_run,verify-changes $(MAKEVN_VERIFY_CHANGES_ARGS))

vn-pr-verify:
	$(call makevn_run,pr-verify $(MAKEVN_PR_VERIFY_ARGS))

vn-docker-up:
	$(call makevn_run,docker-up)

vn-docker-down:
	$(call makevn_run,docker-down)

vn-docker-ps:
	$(call makevn_run,docker-ps)

vn-run:
	$(call makevn_run,run)

vn-jdk-current:
	$(call makevn_run,jdk current)

vn-jdk-list:
	$(call makevn_run,jdk list)

vn-exec:
	@test -n "$(strip $(MAKEVN_ARGS))" || { printf '%s\n' 'Usage: make vn-exec MAKEVN_ARGS="-- mvn -v"'; exit 1; }
	$(call makevn_run,exec $(MAKEVN_ARGS))
