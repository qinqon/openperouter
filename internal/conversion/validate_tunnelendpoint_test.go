// SPDX-License-Identifier:Apache-2.0

package conversion

import (
	"fmt"
	"reflect"
	"strings"
	"testing"

	apiextensionsv1 "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

	"github.com/openperouter/openperouter/api/v1alpha1"
	"github.com/openperouter/openperouter/internal/hostnetwork"
)

const ipvlanL3StaticConfig = `{
  "cniVersion": "1.0.0",
  "name": "cloud-underlay",
  "plugins": [
    {
      "type": "ipvlan",
      "master": "eth0",
      "mode": "l3",
      "capabilities": {"ips": true},
      "ipam": {"type": "static", "routes": [{"dst": "10.250.1.0/24"}]}
    }
  ]
}`

func TestValidateTunnelEndpointInterface(t *testing.T) {
	tests := []struct {
		name     string
		underlay v1alpha1.Underlay
		wantErr  string
	}{
		{
			name:     "loopback endpoint is always accepted",
			underlay: underlayWithEndpointOnInterface(nil, cniDevice(ipvlanL3StaticConfig, "net1", "")),
		},
		{
			name:     "endpoint on a matching ipvlan l3 static cni device",
			underlay: underlayWithEndpointOnInterface(new("net1"), cniDevice(ipvlanL3StaticConfig, "net1", "")),
		},
		{
			name:     "endpoint interface resolves the default cni interface name",
			underlay: underlayWithEndpointOnInterface(new("net1"), cniDevice(ipvlanL3StaticConfig, "", "")),
		},
		{
			name: "endpoint interface allows unrelated capability arguments",
			underlay: underlayWithEndpointOnInterface(new("net1"),
				cniDevice(ipvlanL3StaticConfig, "net1", `{"mac":"02:42:c0:a8:01:0a"}`)),
		},
		{
			name:     "endpoint interface name does not match the cni device",
			underlay: underlayWithEndpointOnInterface(new("net2"), cniDevice(ipvlanL3StaticConfig, "net1", "")),
			wantErr:  `tunnelEndpoint.interfaceName "net2" does not match the CNIDevice interface "net1"`,
		},
		{
			name: "endpoint interface references a network device",
			underlay: underlayWithEndpointOnInterface(new("eth0"), v1alpha1.UnderlayInterface{
				Type:          v1alpha1.UnderlayInterfaceTypeNetworkDevice,
				NetworkDevice: &v1alpha1.NetworkDevice{InterfaceName: "eth0"},
			}),
			wantErr: "must reference a CNIDevice interface",
		},
		{
			name: "endpoint interface with more than one underlay interface",
			underlay: underlayWithEndpointOnInterface(new("net1"),
				cniDevice(ipvlanL3StaticConfig, "net1", ""), cniDevice(ipvlanL3StaticConfig, "net2", "")),
			wantErr: "requires exactly one underlay interface, got 2",
		},
		{
			name: "endpoint interface with user supplied ips",
			underlay: underlayWithEndpointOnInterface(new("net1"),
				cniDevice(ipvlanL3StaticConfig, "net1", `{"ips":["192.168.11.5/32"]}`)),
			wantErr: "runtimeConfig.ips is reserved",
		},
		{
			name: "endpoint interface with static ipam addresses",
			underlay: underlayWithEndpointOnInterface(new("net1"), cniDevice(pluginConfig(
				`"type":"ipvlan","mode":"l3","capabilities":{"ips":true},`+
					`"ipam":{"type":"static","addresses":[{"address":"192.168.11.5/32"}]}`), "net1", "")),
			wantErr: "ipam.addresses must not be set",
		},
		{
			name: "endpoint interface without the ips capability",
			underlay: underlayWithEndpointOnInterface(new("net1"), cniDevice(pluginConfig(
				`"type":"ipvlan","mode":"l3","ipam":{"type":"static"}`), "net1", "")),
			wantErr: `must declare the "ips" capability`,
		},
		{
			name: "endpoint interface with a macvlan plugin",
			underlay: underlayWithEndpointOnInterface(new("net1"), cniDevice(pluginConfig(
				`"type":"macvlan","capabilities":{"ips":true},"ipam":{"type":"static"}`), "net1", "")),
			wantErr: `the cni plugin must be "ipvlan", got "macvlan"`,
		},
		{
			name: "endpoint interface with ipvlan l2",
			underlay: underlayWithEndpointOnInterface(new("net1"), cniDevice(pluginConfig(
				`"type":"ipvlan","mode":"l2","capabilities":{"ips":true},"ipam":{"type":"static"}`), "net1", "")),
			wantErr: `must use mode "l3", got "l2"`,
		},
		{
			name: "endpoint interface with dhcp ipam",
			underlay: underlayWithEndpointOnInterface(new("net1"), cniDevice(pluginConfig(
				`"type":"ipvlan","mode":"l3","capabilities":{"ips":true},"ipam":{"type":"dhcp"}`), "net1", "")),
			wantErr: `must use ipam type "static", got "dhcp"`,
		},
		{
			name: "endpoint interface with a chained plugin",
			underlay: underlayWithEndpointOnInterface(new("net1"), cniDevice(`{
  "cniVersion": "1.0.0", "name": "u",
  "plugins": [
    {"type":"ipvlan","mode":"l3","capabilities":{"ips":true},"ipam":{"type":"static"}},
    {"type":"tuning"}
  ]}`, "net1", "")),
			wantErr: "must contain exactly one plugin, got 2",
		},
		{
			name: "endpoint interface with check disabled",
			underlay: underlayWithEndpointOnInterface(new("net1"), cniDevice(`{
  "cniVersion": "1.0.0", "name": "u", "disableCheck": true,
  "plugins": [{"type":"ipvlan","mode":"l3","capabilities":{"ips":true},"ipam":{"type":"static"}}]}`,
				"net1", "")),
			wantErr: "disableCheck must not be set",
		},
		{
			name: "endpoint interface with srv6",
			underlay: func() v1alpha1.Underlay {
				u := underlayWithEndpointOnInterface(new("net1"), cniDevice(ipvlanL3StaticConfig, "net1", ""))
				u.Spec.TunnelEndpoint.CIDRs = append(u.Spec.TunnelEndpoint.CIDRs, "2001:db8::/64")
				u.Spec.ISIS = &v1alpha1.ISISConfig{BaseNet: "49.0001.0000.0000.0001.00"}
				u.Spec.SRV6 = &v1alpha1.SRV6Config{
					Locator: v1alpha1.SRV6Locator{BasePrefix: "fd00::/48", Format: "usid-f3216"},
				}
				return u
			}(),
			wantErr: "not supported together with srv6",
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := ValidateUnderlays([]v1alpha1.Underlay{tt.underlay})
			if tt.wantErr == "" {
				if err != nil {
					t.Fatalf("expected the underlay to be valid, got %v", err)
				}
				return
			}
			if err == nil {
				t.Fatalf("expected error containing %q, got nil", tt.wantErr)
			}
			if !strings.Contains(err.Error(), tt.wantErr) {
				t.Fatalf("expected error containing %q, got %q", tt.wantErr, err.Error())
			}
		})
	}
}

func TestAPItoHostConfigTunnelEndpointOnInterface(t *testing.T) {
	underlay := underlayWithEndpointOnInterface(new("net1"),
		cniDevice(ipvlanL3StaticConfig, "net1", `{"mac":"02:42:c0:a8:01:0a"}`))
	underlay.Spec.TunnelEndpoint.CIDRs = []string{"192.168.11.0/24", "2001:db8::/64"}

	apiConfig := APIConfigData{
		Underlays: []v1alpha1.Underlay{underlay},
		L3VNIs: []v1alpha1.L3VNI{{
			ObjectMeta: metav1.ObjectMeta{Name: "red"},
			Spec:       v1alpha1.L3VNISpec{VRF: "red", VNI: 100},
		}},
		L2VNIs: []v1alpha1.L2VNI{{
			ObjectMeta: metav1.ObjectMeta{Name: "blue"},
			Spec:       v1alpha1.L2VNISpec{VNI: 200},
		}},
	}

	got, err := APItoHostConfig(3, "namespace", apiConfig)
	if err != nil {
		t.Fatalf("APItoHostConfig() unexpected error: %v", err)
	}

	wantUnderlay := hostnetwork.UnderlayParams{
		TargetNS: "namespace",
		UnderlayInterfaces: []hostnetwork.UnderlayInterface{{
			InterfaceName: "net1",
			Kind:          hostnetwork.UnderlayInterfaceCNIDev,
			CNI: &hostnetwork.CNIDeviceParams{
				Config: []byte(ipvlanL3StaticConfig),
				CapabilityArgs: map[string]any{
					"mac": "02:42:c0:a8:01:0a",
					"ips": []any{"192.168.11.3/32", "2001:db8::3/128"},
				},
			},
		}},
		TunnelEndpoint: &hostnetwork.UnderlayTunnelEndpointParams{
			IPv4CIDR:      "192.168.11.3/32",
			IPv6CIDR:      "2001:db8::3/128",
			InterfaceName: "net1",
		},
	}
	if !reflect.DeepEqual(got.Underlay, wantUnderlay) {
		t.Errorf("APItoHostConfig() underlay = %+v, want %+v", got.Underlay, wantUnderlay)
	}
	if got.L3VNIs[0].VTEPDevice != "net1" || got.L3VNIs[0].VTEPIP != "192.168.11.3/32" {
		t.Errorf("L3VNI vtep = %s/%s, want net1/192.168.11.3/32", got.L3VNIs[0].VTEPDevice, got.L3VNIs[0].VTEPIP)
	}
	if got.L2VNIs[0].VTEPDevice != "net1" || got.L2VNIs[0].VTEPIP != "192.168.11.3/32" {
		t.Errorf("L2VNI vtep = %s/%s, want net1/192.168.11.3/32", got.L2VNIs[0].VTEPDevice, got.L2VNIs[0].VTEPIP)
	}
}

func TestAPItoHostConfigTunnelEndpointOnLoopbackLeavesCNIUntouched(t *testing.T) {
	underlay := underlayWithEndpointOnInterface(nil, cniDevice(ipvlanL3StaticConfig, "net1", ""))
	apiConfig := APIConfigData{
		Underlays: []v1alpha1.Underlay{underlay},
		L3VNIs: []v1alpha1.L3VNI{{
			ObjectMeta: metav1.ObjectMeta{Name: "red"},
			Spec:       v1alpha1.L3VNISpec{VRF: "red", VNI: 100},
		}},
	}

	got, err := APItoHostConfig(0, "namespace", apiConfig)
	if err != nil {
		t.Fatalf("APItoHostConfig() unexpected error: %v", err)
	}
	if got.Underlay.UnderlayInterfaces[0].CNI.CapabilityArgs != nil {
		t.Errorf("expected no capability args on a non endpoint cni device, got %v",
			got.Underlay.UnderlayInterfaces[0].CNI.CapabilityArgs)
	}
	if got.Underlay.TunnelEndpoint.InterfaceName != "" || got.L3VNIs[0].VTEPDevice != "" {
		t.Errorf("expected the tunnel endpoint on the loopback, got underlay %q vni %q",
			got.Underlay.TunnelEndpoint.InterfaceName, got.L3VNIs[0].VTEPDevice)
	}
}

func underlayWithEndpointOnInterface(endpointIface *string,
	interfaces ...v1alpha1.UnderlayInterface) v1alpha1.Underlay {
	return v1alpha1.Underlay{
		ObjectMeta: metav1.ObjectMeta{Name: "underlay"},
		Spec: v1alpha1.UnderlaySpec{
			ASN:        65001,
			Interfaces: interfaces,
			TunnelEndpoint: &v1alpha1.TunnelEndpointConfig{
				CIDRs:         []string{"192.168.11.0/24"},
				InterfaceName: endpointIface,
			},
			Neighbors: []v1alpha1.Neighbor{{
				ASN:     new(int64(64515)),
				Address: new("10.250.1.3"),
			}},
		},
	}
}

func cniDevice(rawConfig, ifName, runtimeConfig string) v1alpha1.UnderlayInterface {
	device := &v1alpha1.CNIDevice{
		Type:      v1alpha1.CNIConfigTypeRawConfig,
		RawConfig: &apiextensionsv1.JSON{Raw: []byte(rawConfig)},
	}
	if ifName != "" {
		device.InterfaceName = new(ifName)
	}
	if runtimeConfig != "" {
		device.RuntimeConfig = &apiextensionsv1.JSON{Raw: []byte(runtimeConfig)}
	}
	return v1alpha1.UnderlayInterface{
		Type:      v1alpha1.UnderlayInterfaceTypeCNIDevice,
		CNIDevice: device,
	}
}

func pluginConfig(plugin string) string {
	return fmt.Sprintf(`{"cniVersion":"1.0.0","name":"u","plugins":[{%s}]}`, plugin)
}
