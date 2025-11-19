# Copyright © 2021 Luther Systems, Ltd. All right reserved.

# common.phylum.mk
#
# A base makefile for working with phyla (collections of lisp code making up a
# smart contract).

PROJECT_REL_DIR:=..
include ${PROJECT_REL_DIR}/common.mk

SOURCE_FILES=$(shell find . -name "*.lisp" | grep -v '/build')

PHYLUM_NAME ?= ${PROJECT}.zip
PHYLUM_PATH=build/${PROJECT}-${BUILD_VERSION}/${PHYLUM_NAME}

SHIRO_TEST=${DOCKER_RUN} -v ${PHYLUMDIR}:/tmp -w /tmp ${SHIROTESTER_IMAGE}:${SHIROTESTER_VERSION}

# This is an unfortunate hack to get around DnD mounts which must
# be relative to the host machine.
PHYLUMDIR?=${CURDIR}
PHYLUM_PACKAGE=${PROJECT}

.PHONY: default
default: build

.PHONY: build
build: ${PHYLUM_PATH}

.PHONY: clean
clean:
	rm -rf build

.PHONY: test
test: shiro-test
	@

.PHONY: shiro-test
shiro-test: build
	${SHIRO_TEST} unit-tests --verbose . $(shell find . -name "*_test.lisp" -type f | grep -v '/build' | sed 's|^\./||' | tr '\n' ' ')

.PHONY: repl
repl:
	${SHIRO_TEST} repl --in-package ${PHYLUM_PACKAGE} .

${PHYLUM_PATH}: ${SOURCE_FILES}
	mkdir -p $(dir $@)
	@for file in $^; do \
		dest=$(dir $@)$${file#./}; \
		mkdir -p $$(dirname "$$dest"); \
		cp "$$file" "$$dest"; \
	done
	sed -i='.orig' "s/LUTHER_PROJECT_VERSION/${VERSION}/" $(dir $@)/main.lisp
	sed -i='.orig' "s/LUTHER_PROJECT_BUILD_ID/${BUILD_ID}/" $(dir $@)/main.lisp
	cd $(dir $@) && find . -name "*.lisp" -type f | zip $(notdir $@) -@

.PHONY: phylum-path
phylum-path:
	@echo ${PHYLUM_PATH}