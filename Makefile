all: build

APP_NAME=cluster-monitoring-operator
BIN=operator
MAIN_PKG=github.com/openshift/$(APP_NAME)/cmd/operator
REPO?=quay.io/openshift/$(APP_NAME)
TAG?=$(shell git rev-parse --short HEAD)
ENVVAR=GOOS=linux GOARCH=amd64 CGO_ENABLED=0
NAMESPACE=openshift-monitoring
KUBECONFIG?=$(HOME)/.kube/config
PKGS=$(shell go list ./... | grep -v -E '/vendor/|/test|/examples')
GOOS=linux
VERSION=$(shell cat VERSION | tr -d " \t\n\r")
SRC=$(shell find . -type f -name '*.go') pkg/manifests/bindata.go
FIRST_GOPATH:=$(firstword $(subst :, ,$(shell go env GOPATH)))
EMBEDMD_BIN=$(FIRST_GOPATH)/bin/embedmd
GOBINDATA_BIN=$(FIRST_GOPATH)/bin/go-bindata
GOJSONTOYAML_BIN=$(FIRST_GOPATH)/bin/gojsontoyaml
# We need jsonnet on Travis; here we default to the user's installed jsonnet binary; if nothing is installed, then install go-jsonnet.
JSONNET_BIN=$(if $(shell which jsonnet 2>/dev/null),$(shell which jsonnet 2>/dev/null),$(FIRST_GOPATH)/bin/jsonnet)
JB_BIN=$(FIRST_GOPATH)/bin/jb
ASSETS=$(shell grep -oh 'assets/.*\.yaml' pkg/manifests/manifests.go)
JSONNET_SRC=$(shell find ./jsonnet -type f)
JSONNET_VENDOR=jsonnet/jsonnetfile.lock.json jsonnet/vendor
GO_BUILD_RECIPE=GOOS=$(GOOS) go build --ldflags="-s -X github.com/openshift/cluster-monitoring-operator/pkg/operator.Version=$(VERSION)" -o $(BIN) $(MAIN_PKG)

build: $(BIN)

$(BIN): $(SRC)
	$(GO_BUILD_RECIPE)

# We need this Make target so that we can build the operator depending
# only on what is checked into the repo, without calling to the internet.
operator-no-deps:
	$(GO_BUILD_RECIPE)

run: build
	./$(BIN)

crossbuild:
	$(ENVVAR) $(MAKE) build

container:
	docker build -t $(REPO):$(TAG) .

push: container
	docker push $(REPO):$(TAG)

clean:
	rm -f $(BIN)
	go clean -r $(MAIN_PKG)
	docker images -q $(REPO) | xargs --no-run-if-empty docker rmi --force
	rm -rf jsonnet/vendor

docs:
	embedmd -w `find Documentation -name "*.md"`

pkg/manifests/bindata.go: $(ASSETS) $(GOBINDATA_BIN)
	# Using "-modtime 1" to make generate target deterministic. It sets all file time stamps to unix timestamp 1
	$(GOBINDATA_BIN) -mode 420 -modtime 1 -pkg manifests -o $@ assets/...

$(ASSETS): $(JSONNET_SRC) $(JSONNET_VENDOR) hack/build-jsonnet.sh
	./hack/build-jsonnet.sh

$(JSONNET_VENDOR): jsonnet/jsonnetfile.json
	cd jsonnet && jb install

generate: clean
	docker build -t tpo-generate -f Dockerfile.generate .
	docker run \
		--rm \
		--security-opt label=disable \
		-v `pwd`:/go/src/github.com/openshift/cluster-monitoring-operator \
		-u=$(shell id -u $(USER)):$(shell id -g $(USER)) \
		-w /go/src/github.com/openshift/cluster-monitoring-operator \
		tpo-generate \
		make dependencies pkg/manifests/bindata.go merge-cluster-roles docs

dependencies: $(JB_BIN) $(JSONNET_BIN) $(GOBINDATA_BIN) $(GOJSONTOYAML_BIN) $(EMBEDMD_BIN)

$(EMBEDMD_BIN):
	go get -u github.com/campoy/embedmd

$(GOBINDATA_BIN):
	go get -u github.com/jteeuwen/go-bindata/...

$(GOJSONTOYAML_BIN):
	go get -u github.com/brancz/gojsontoyaml

$(JB_BIN):
	go get -u github.com/jsonnet-bundler/jsonnet-bundler/cmd/jb

$(JSONNET_BIN):
	go get -u github.com/google/go-jsonnet/jsonnet

test-unit:
	go test $(PKGS)

test-e2e:
	go test -v -timeout=20m ./test/e2e/ --kubeconfig $(KUBECONFIG)

vendor:
	govendor add +external

merge-cluster-roles: manifests/02-role.yaml
manifests/02-role.yaml: $(ASSETS) hack/merge_cluster_roles.py hack/cluster-monitoring-operator-role.yaml.in
	python2 hack/merge_cluster_roles.py hack/cluster-monitoring-operator-role.yaml.in `find assets | grep role | grep -v "role-binding" | sort` > manifests/02-role.yaml

.PHONY: all build operator-no-deps run crossbuild container push clean deps generate dependencies test test-e2e merge-cluster-roles
