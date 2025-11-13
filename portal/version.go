// Copyright © 2024 Luther Systems, Ltd. All right reserved.
package main

import (
	"fmt"

	"github.com/luthersystems/cdcs/portal/version"
)

type versionCmd struct {
	baseCmd
}

func (r *versionCmd) Run() error {
	fmt.Println(version.Version)
	return nil
}
