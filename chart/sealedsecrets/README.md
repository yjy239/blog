## 描述

加密kubernetes secret

## 使用步骤

1. 安装kubeseal
```
GOOS=$(go env GOOS) && GOARCH=$(go env GOARCH) && wget https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.7.0/kubeseal-$GOOS-$GOARCH && sudo install -m 755 kubeseal-$GOOS-$GOARCH /usr/local/bin/kubeseal
```
建议: 
  测试/生产环境使用: {{ 项目名称}}-{{ 环境名称 }}-secret 作为 secret.name
  开发环境使用: {{ 项目名称}}-{{ 环境名称 }}-secret-{{ 开发人员名字 }} 作为 secret.name
建议以env.unsealed作为原始环境变量文件, 在.gitignore文件添加*.unsealed
2. 生成sealedsecret: 
```
kubectl create secret generic -n `basename \`pwd\`` {{ secret.name }} --dry-run --from-env-file={{ env_file }} -o yaml | kubeseal --cert cert.pem --format=yaml > sealedsecret.yaml
```
3. 加密secret会依赖文件中的name和namespace字段, 一定要仔细核对, 否则secret会生成失败.
4. 上面的命令会取当前目录名作为namespace字段, 如果命名空间错误, 请修改命令中的-n 参数, 重新生成sealsecret.yml
5. 到你的values/*.yml 指定sealedsecret的path字段
