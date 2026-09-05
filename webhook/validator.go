package main

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"

	admissionv1 "k8s.io/api/admission/v1"
	appsv1 "k8s.io/api/apps/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

const maxBody = 3 << 20

func handleValidate(w http.ResponseWriter, r *http.Request) {
	review, err := decodeReview(w, r)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	response := &admissionv1.AdmissionResponse{UID: review.Request.UID}

	var deploy appsv1.Deployment
	switch err := json.Unmarshal(review.Request.Object.Raw, &deploy); {
	case err != nil:
		response.Result = &metav1.Status{Message: "could not decode the Deployment: " + err.Error()}
	default:
		if missing := missingRequests(&deploy); len(missing) > 0 {
			reason := strings.Join(missing, "; ")
			response.Result = &metav1.Status{Message: "resource requests are required. " + reason}
			log.Printf("denied %s/%s: %s", review.Request.Namespace, deploy.Name, reason)
		} else {
			response.Allowed = true
		}
	}

	// without these the apiserver rejects the reply, and it reads as a broken webhook
	out := admissionv1.AdmissionReview{
		TypeMeta: metav1.TypeMeta{
			APIVersion: admissionv1.SchemeGroupVersion.String(),
			Kind:       "AdmissionReview",
		},
		Response: response,
	}

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(out); err != nil {
		log.Printf("encoding response: %v", err)
	}
}

func decodeReview(w http.ResponseWriter, r *http.Request) (*admissionv1.AdmissionReview, error) {
	body, err := io.ReadAll(http.MaxBytesReader(w, r.Body, maxBody))
	if err != nil {
		return nil, fmt.Errorf("reading body: %w", err)
	}

	var review admissionv1.AdmissionReview
	if err := json.Unmarshal(body, &review); err != nil {
		return nil, fmt.Errorf("decoding AdmissionReview: %w", err)
	}
	if review.Request == nil {
		return nil, errors.New("AdmissionReview carried no request")
	}
	return &review, nil
}

// a request of zero is treated as missing - it schedules exactly like no request at all
func missingRequests(d *appsv1.Deployment) []string {
	var missing []string

	check := func(kind string, containers []corev1.Container) {
		for _, c := range containers {
			if c.Resources.Requests.Cpu().IsZero() {
				missing = append(missing, fmt.Sprintf("%s %q has no cpu request", kind, c.Name))
			}
			if c.Resources.Requests.Memory().IsZero() {
				missing = append(missing, fmt.Sprintf("%s %q has no memory request", kind, c.Name))
			}
		}
	}

	spec := d.Spec.Template.Spec
	check("container", spec.Containers)
	// native sidecars live here and are counted in the pod's requests like any container
	check("initContainer", spec.InitContainers)

	return missing
}
