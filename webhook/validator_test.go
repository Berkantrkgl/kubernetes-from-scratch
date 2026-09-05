package main

import (
	"testing"

	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
)

func container(name, cpu, memory string) corev1.Container {
	c := corev1.Container{Name: name}
	requests := corev1.ResourceList{}
	if cpu != "" {
		requests[corev1.ResourceCPU] = resource.MustParse(cpu)
	}
	if memory != "" {
		requests[corev1.ResourceMemory] = resource.MustParse(memory)
	}
	if len(requests) > 0 {
		c.Resources.Requests = requests
	}
	return c
}

func deployment(containers, initContainers []corev1.Container) *appsv1.Deployment {
	return &appsv1.Deployment{
		Spec: appsv1.DeploymentSpec{
			Template: corev1.PodTemplateSpec{
				Spec: corev1.PodSpec{
					Containers:     containers,
					InitContainers: initContainers,
				},
			},
		},
	}
}

func TestMissingRequests(t *testing.T) {
	tests := []struct {
		name   string
		deploy *appsv1.Deployment
		want   int
	}{
		{
			name:   "both requests set",
			deploy: deployment([]corev1.Container{container("app", "100m", "256Mi")}, nil),
			want:   0,
		},
		{
			name:   "memory missing",
			deploy: deployment([]corev1.Container{container("app", "100m", "")}, nil),
			want:   1,
		},
		{
			name:   "no resources at all",
			deploy: deployment([]corev1.Container{container("app", "", "")}, nil),
			want:   2,
		},
		{
			name:   "an explicit zero is not a request",
			deploy: deployment([]corev1.Container{container("app", "0", "256Mi")}, nil),
			want:   1,
		},
		{
			name: "a sidecar without requests is caught too",
			deploy: deployment(
				[]corev1.Container{container("app", "100m", "256Mi")},
				[]corev1.Container{container("fluent-bit", "", "")},
			),
			want: 2,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := missingRequests(tt.deploy)
			if len(got) != tt.want {
				t.Errorf("got %d violations %v, want %d", len(got), got, tt.want)
			}
		})
	}
}
