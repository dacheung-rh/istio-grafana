#!/bin/bash

ISTIO_GRAFANA_NS=$1

if [[ -z $ISTIO_GRAFANA_NS || $ISTIO_GRAFANA_NS == null ]]; then
  ISTIO_GRAFANA_NS=istio-grafana
fi

echo "Istio Grafana namespace: " $ISTIO_GRAFANA_NS

echo "========================================================================"
echo "Create service account, role and rolebinding"
echo "========================================================================"

oc apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: $ISTIO_GRAFANA_NS-serviceaccount
  namespace: $ISTIO_GRAFANA_NS
  labels:
    app: istio-grafana
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: $ISTIO_GRAFANA_NS-cluster-monitoring-binding
  labels:
    app: istio-grafana
subjects:
  - kind: ServiceAccount
    name: $ISTIO_GRAFANA_NS-serviceaccount
    namespace: $ISTIO_GRAFANA_NS
roleRef:
  kind: ClusterRole
  name: cluster-monitoring-view
  apiGroup: rbac.authorization.k8s.io
EOF

echo "========================================================================"
echo "Create grafana token"
echo "========================================================================"

oc apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: grafana-long-lived-secret
  namespace: $ISTIO_GRAFANA_NS  
  annotations:
    kubernetes.io/service-account.name: $ISTIO_GRAFANA_NS-serviceaccount
type: kubernetes.io/service-account-token
EOF

sleep 5

export GRAFANA_ACCESS_TOKEN=$(oc describe secret grafana-long-lived-secret -n $ISTIO_GRAFANA_NS | grep token: | awk '{print $2}')
echo $GRAFANA_ACCESS_TOKEN


echo "========================================================================"
echo "Create grafana datasource, dashboard provider and grafana configure"
echo "========================================================================"

cat <<EOF > datasource.yaml
apiVersion: 1
datasources:
- name: Prometheus
  type: prometheus
  url: https://thanos-querier.openshift-monitoring.svc.cluster.local:9091
  access: proxy
  basicAuth: false
  withCredentials: false
  isDefault: true
  jsonData:
    timeInterval: 5s
    tlsSkipVerify: true
    httpHeaderName1: "Authorization"
  secureJsonData:
    httpHeaderValue1: "Bearer ${GRAFANA_ACCESS_TOKEN}"
  editable: true
EOF

cat <<EOF > dashboardproviders.yaml
apiVersion: 1
providers:
- disableDeletion: false
  folder: istio
  name: istio
  options:
    path: /var/lib/grafana/dashboards/istio
  orgId: 1
  type: file
EOF

cat <<EOF > grafana.ini
[analytics]
check_for_updates = true
[grafana_net]
url = https://grafana.net
[log]
mode = console
[paths]
data = /data/grafana
logs = /var/log/grafana
plugins = /var/lib/grafana/plugins
provisioning = /etc/grafana/provisioning
EOF

oc create configmap grafana-config --from-file=datasource.yaml  --from-file=dashboardproviders.yaml  --from-file=grafana.ini -n $ISTIO_GRAFANA_NS -oyaml --dry-run=client | oc apply -f -

echo "========================================================================"
echo "Deploy dashboards on configmap"
echo "========================================================================"
echo
sleep 2
echo
echo "---------------------------------------------"

for i in $(ls cm*.yaml | xargs -n 1); do cat $i | sed "s/ISTIO_GRAFANA_NS/$ISTIO_GRAFANA_NS/g" | oc apply -f - ; done

echo "========================================================================"
echo "Deploy grafana application"
echo "========================================================================"
echo
sleep 2
echo
echo "---------------------------------------------"

oc apply -f - <<EOF
apiVersion: v1
stringData:
  adminpassword: redhat
kind: Secret
metadata:
  name: grafana-secret
  namespace: istio-grafana
type: Opaque
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: grafana
  namespace: $ISTIO_GRAFANA_NS    
  labels:
    app: istio-grafana
spec:
  replicas: 1
  selector:
    matchLabels:
      name: grafana
  template:
    metadata:
      labels:
        name: grafana
    spec:
      serviceAccountName: $ISTIO_GRAFANA_NS-serviceaccount
      containers:
      - name: grafana
        env:
        - name: GF_SECURITY_ADMIN_PASSWORD
          valueFrom:
            secretKeyRef:
              key: adminpassword
              name: grafana-secret
        - name: GF_SECURITY_ADMIN_USER
          value: admin
        - name: GF_USERS_ALLOW_SIGN_UP
          value: "false"
        - name: GF_LOG_MODE
          value: console
        - name: GF_AUTH_ANONYMOUS_ENABLED
          value: "false"      
        image: grafana/grafana:11.2.0
        ports:
        - name: grafana
          containerPort: 3000
          protocol: TCP
        volumeMounts:
        - name: grafana-config
          mountPath: /etc/grafana/grafana.ini
          subPath: grafana.ini
        - name: grafana-data
          mountPath: /var/lib/grafana
        - name: grafana-logs
          mountPath: /var/log/grafana
        - name: dashboards-istio-istio-extension-dashboard
          readOnly: true
          mountPath: /var/lib/grafana/dashboards/istio/istio-extension-dashboard.json
          subPath: istio-extension-dashboard.json
        - name: dashboards-istio-istio-mesh-dashboard
          readOnly: true
          mountPath: /var/lib/grafana/dashboards/istio/istio-mesh-dashboard.json
          subPath: istio-mesh-dashboard.json
        - name: dashboards-istio-istio-performance-dashboard
          readOnly: true
          mountPath: /var/lib/grafana/dashboards/istio/istio-performance-dashboard.json
          subPath: istio-performance-dashboard.json
        - name: dashboards-istio-istio-service-dashboard
          readOnly: true
          mountPath: /var/lib/grafana/dashboards/istio/istio-service-dashboard.json
          subPath: istio-service-dashboard.json
        - name: dashboards-istio-istio-workload-dashboard
          readOnly: true
          mountPath: /var/lib/grafana/dashboards/istio/istio-workload-dashboard.json
          subPath: istio-workload-dashboard.json
        - name: dashboards-istio-pilot-dashboard
          readOnly: true
          mountPath: /var/lib/grafana/dashboards/istio/pilot-dashboard.json
          subPath: pilot-dashboard.json          
        - name: grafana-config
          mountPath: /etc/grafana/provisioning/dashboards/dashboardproviders.yaml
          readOnly: true
          subPath: dashboardproviders.yaml
        - name: grafana-config
          mountPath: /etc/grafana/provisioning/datasources/datasource.yaml
          readOnly: true
          subPath: datasource.yaml
        readinessProbe:
          httpGet:
            path: /api/health
            port: 3000
          initialDelaySeconds: 5
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /api/health
            port: 3000
          initialDelaySeconds: 15
          periodSeconds: 20
      volumes:
      - name: grafana-data
        emptyDir: {}
      - name: grafana-logs
        emptyDir: {}
      - name: grafana-config
        configMap:
          name: grafana-config
          defaultMode: 420
      - name: dashboards-istio-istio-extension-dashboard
        configMap:
          name: istio-grafana-configuration-dashboards-istio-extension-dashboard
          defaultMode: 420
      - name: dashboards-istio-istio-mesh-dashboard
        configMap:
          name: istio-grafana-configuration-dashboards-istio-mesh-dashboard
          defaultMode: 420
      - name: dashboards-istio-istio-performance-dashboard
        configMap:
          name: istio-grafana-configuration-dashboards-istio-performance-dashboard
          defaultMode: 420
      - name: dashboards-istio-istio-service-dashboard
        configMap:
          name: istio-grafana-configuration-dashboards-istio-service-dashboard
          defaultMode: 420
      - name: dashboards-istio-istio-workload-dashboard
        configMap:
          name: istio-grafana-configuration-dashboards-istio-workload-dashboard
          defaultMode: 420
      - name: dashboards-istio-pilot-dashboard
        configMap:
          name: istio-grafana-configuration-dashboards-pilot-dashboard
          defaultMode: 420
---
apiVersion: v1
kind: Service
metadata:
  name: grafana
  namespace: $ISTIO_GRAFANA_NS
  labels:
    app: istio
spec:
  ports:
  - name: grafana
    port: 3000
    targetPort: 3000
    protocol: TCP
  selector:
    name: grafana
  type: ClusterIP
EOF

oc create route edge istio-grafana --service=grafana --port=3000 --namespace=$ISTIO_GRAFANA_NS -oyaml --dry-run=client | oc apply -f -




