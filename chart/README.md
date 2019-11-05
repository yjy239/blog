## 描述

kubernetes helm chart 模板

## 使用步骤

1. 修改chart.yaml
2. 修改values.yaml
3. 调试chart， 可以使用helm install -f your-values-path --dry-run --debug your-chart-path/, 来检查自己写的chart， 这个命令并不会真正安装到集群， 而是渲染出将要安装到集群的manifest
4. kubectl port-forward pod_name loca_lport: pod_port 把pod端口映射到本地端口
5. k exec curl -- curl -s service_ip   来调试service是否正常
