// SPDX-License-Identifier:Apache-2.0

// RR controller binary — configures the local node's FRR process as an iBGP route reflector.
// Deployed as a 2-replica Deployment (anti-affinity ensures two different RR nodes).
package main

import (
	"context"
	"flag"
	"fmt"
	"os"

	"github.com/go-logr/logr"
	periov1alpha1 "github.com/openperouter/openperouter/api/v1alpha1"
	"github.com/openperouter/openperouter/internal/controller/rrcontroller"
	"github.com/openperouter/openperouter/internal/logging"
	"github.com/openperouter/openperouter/internal/version"
	v1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/runtime"
	utilruntime "k8s.io/apimachinery/pkg/util/runtime"
	clientgoscheme "k8s.io/client-go/kubernetes/scheme"
	_ "k8s.io/client-go/plugin/pkg/client/auth"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/cache"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"sigs.k8s.io/controller-runtime/pkg/client/config"
	"sigs.k8s.io/controller-runtime/pkg/healthz"
	"sigs.k8s.io/controller-runtime/pkg/metrics/server"
)

var (
	scheme   = runtime.NewScheme()
	setupLog = ctrl.Log.WithName("setup")
)

func init() {
	utilruntime.Must(clientgoscheme.AddToScheme(scheme))
	utilruntime.Must(periov1alpha1.AddToScheme(scheme))
}

func main() {
	var (
		nodeName   string
		namespace  string
		logLevel   string
		probeAddr  string
	)

	flag.StringVar(&nodeName, "nodename", "", "The name of the node this controller runs on")
	flag.StringVar(&namespace, "namespace", "", "The namespace to manage RawFRRConfig objects in")
	flag.StringVar(&logLevel, "loglevel", "info", "Log verbosity level")
	flag.StringVar(&probeAddr, "health-probe-bind-address", ":9082", "Health probe bind address")
	flag.Parse()

	if nodeName == "" {
		fmt.Println("--nodename is required")
		os.Exit(1)
	}
	if namespace == "" {
		fmt.Println("--namespace is required")
		os.Exit(1)
	}

	logger, err := logging.New(logLevel)
	if err != nil {
		fmt.Println("unable to init logger", err)
		os.Exit(1)
	}
	ctrl.SetLogger(logr.FromSlogHandler(logger.Handler()))
	setupLog.Info("version", "version", version.Version())

	k8sConfig, err := config.GetConfig()
	if err != nil {
		logger.Error("unable to get kubernetes config", "error", err)
		os.Exit(1)
	}

	mgr, err := ctrl.NewManager(k8sConfig, ctrl.Options{
		Scheme:                 scheme,
		HealthProbeBindAddress: probeAddr,
		LeaderElection:         false,
		Metrics: server.Options{
			BindAddress: "0",
		},
		Cache: cache.Options{
			ByObject: map[client.Object]cache.ByObject{
				// Cache all nodes so we can react to label/annotation changes.
				&v1.Node{}: {
					Transform: cache.TransformStripManagedFields(),
				},
			},
		},
	})
	if err != nil {
		logger.Error("unable to create manager", "error", err)
		os.Exit(1)
	}

	if err := mgr.AddHealthzCheck("healthz", healthz.Ping); err != nil {
		logger.Error("unable to set up health check", "error", err)
		os.Exit(1)
	}
	if err := mgr.AddReadyzCheck("readyz", healthz.Ping); err != nil {
		logger.Error("unable to set up ready check", "error", err)
		os.Exit(1)
	}

	reconciler := &rrcontroller.RRReconciler{
		Client:    mgr.GetClient(),
		Scheme:    mgr.GetScheme(),
		MyNode:    nodeName,
		Namespace: namespace,
		Logger:    logger,
	}

	if err := reconciler.SetupWithManager(mgr); err != nil {
		logger.Error("unable to setup RR controller", "error", err)
		os.Exit(1)
	}

	ctx := ctrl.SetupSignalHandler()

	// Register a shutdown hook to clean up RR config when the pod terminates.
	go func() {
		<-ctx.Done()
		// Use a fresh background context since the main context is already done.
		cleanupCtx := context.Background()
		reconciler.Shutdown(cleanupCtx)
	}()

	setupLog.Info("starting RR controller manager")
	if err := mgr.Start(ctx); err != nil {
		logger.Error("problem running RR controller manager", "error", err)
		os.Exit(1)
	}
}
