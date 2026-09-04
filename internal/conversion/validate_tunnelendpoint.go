// SPDX-License-Identifier:Apache-2.0

package conversion

import (
	"encoding/json"
	"errors"
	"fmt"

	"github.com/containernetworking/cni/libcni"
	apiextensionsv1 "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/v1"
	"k8s.io/utils/ptr"

	"github.com/openperouter/openperouter/api/v1alpha1"
	"github.com/openperouter/openperouter/internal/cniinvoker"
)

const (
	ipvlanPluginType = "ipvlan"
	ipvlanModeL3     = "l3"
	staticIPAMType   = "static"
)

// validateTunnelEndpointInterface checks that, when the tunnel endpoint is
// placed on an interface instead of the loopback, the referenced interface is
// the sole underlay interface, is a CNIDevice, and its CNI chain is the one
// supported for delivering the controller-derived addresses: a single ipvlan
// plugin in l3 mode with static IPAM declaring the ips capability. The
// controller owns the addresses on that interface, so any user-supplied ones
// are rejected.
func validateTunnelEndpointInterface(underlay *v1alpha1.Underlay) error {
	tunnelEndpoint := underlay.Spec.TunnelEndpoint
	if tunnelEndpoint == nil || tunnelEndpoint.InterfaceName == nil {
		return nil
	}
	ifName := *tunnelEndpoint.InterfaceName

	if underlay.Spec.SRV6 != nil {
		return errors.New("tunnelEndpoint.interfaceName is not supported together with srv6")
	}
	if len(underlay.Spec.Interfaces) != 1 {
		return fmt.Errorf("tunnelEndpoint.interfaceName %q requires exactly one underlay interface, got %d",
			ifName, len(underlay.Spec.Interfaces))
	}

	iface := underlay.Spec.Interfaces[0]
	if iface.Type != v1alpha1.UnderlayInterfaceTypeCNIDevice || iface.CNIDevice == nil {
		return fmt.Errorf("tunnelEndpoint.interfaceName %q must reference a CNIDevice interface", ifName)
	}
	cniDevice := iface.CNIDevice
	if effectiveName := ptr.Deref(cniDevice.InterfaceName, cniinvoker.DefaultInterfaceName); effectiveName != ifName {
		return fmt.Errorf("tunnelEndpoint.interfaceName %q does not match the CNIDevice interface %q",
			ifName, effectiveName)
	}
	if err := validateTunnelEndpointRuntimeConfig(cniDevice.RuntimeConfig); err != nil {
		return err
	}
	if cniDevice.RawConfig == nil {
		return fmt.Errorf("tunnelEndpoint interface %q has no rawConfig", ifName)
	}
	if err := validateTunnelEndpointCNIChain(cniDevice.RawConfig.Raw); err != nil {
		return fmt.Errorf("tunnelEndpoint interface %q: %w", ifName, err)
	}
	return nil
}

func validateTunnelEndpointRuntimeConfig(runtimeConfig *apiextensionsv1.JSON) error {
	if runtimeConfig == nil {
		return nil
	}
	var capabilityArgs map[string]any
	if err := json.Unmarshal(runtimeConfig.Raw, &capabilityArgs); err != nil {
		return fmt.Errorf("invalid runtimeConfig for the tunnel endpoint interface: %w", err)
	}
	if _, found := capabilityArgs[cniinvoker.IPsCapability]; found {
		return fmt.Errorf("runtimeConfig.%s is reserved on the tunnel endpoint interface, "+
			"the addresses are derived from tunnelEndpoint.cidrs", cniinvoker.IPsCapability)
	}
	return nil
}

// tunnelEndpointPlugin is the subset of an ipvlan plugin entry relevant to
// carrying the tunnel endpoint addresses through static IPAM.
type tunnelEndpointPlugin struct {
	Type         string          `json:"type"`
	Mode         string          `json:"mode"`
	Capabilities map[string]bool `json:"capabilities"`
	IPAM         struct {
		Type      string            `json:"type"`
		Addresses []json.RawMessage `json:"addresses"`
	} `json:"ipam"`
}

func validateTunnelEndpointCNIChain(rawConfig []byte) error {
	confList, err := libcni.NetworkConfFromBytes(rawConfig)
	if err != nil {
		return fmt.Errorf("invalid cni config: %w", err)
	}
	if confList.DisableCheck {
		return errors.New("disableCheck must not be set, cni check is required to detect drift")
	}
	if len(confList.Plugins) != 1 {
		return fmt.Errorf("the cni chain must contain exactly one plugin, got %d", len(confList.Plugins))
	}

	var plugin tunnelEndpointPlugin
	if err := json.Unmarshal(confList.Plugins[0].Bytes, &plugin); err != nil {
		return fmt.Errorf("failed to parse cni plugin config: %w", err)
	}
	if plugin.Type != ipvlanPluginType {
		return fmt.Errorf("the cni plugin must be %q, got %q", ipvlanPluginType, plugin.Type)
	}
	if plugin.Mode != ipvlanModeL3 {
		return fmt.Errorf("the %s plugin must use mode %q, got %q", ipvlanPluginType, ipvlanModeL3, plugin.Mode)
	}
	if plugin.IPAM.Type != staticIPAMType {
		return fmt.Errorf("the %s plugin must use ipam type %q, got %q", ipvlanPluginType, staticIPAMType, plugin.IPAM.Type)
	}
	if len(plugin.IPAM.Addresses) > 0 {
		return fmt.Errorf("ipam.addresses must not be set, the addresses are derived from tunnelEndpoint.cidrs")
	}
	if !plugin.Capabilities[cniinvoker.IPsCapability] {
		return fmt.Errorf("the %s plugin must declare the %q capability to receive the derived addresses",
			ipvlanPluginType, cniinvoker.IPsCapability)
	}
	return nil
}
