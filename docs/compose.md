# compose設計思想

## 基本
- 基本的なサービス構成は共通のcompose.yamlで定義する
- 各環境での設定は、環境ごとのcomposeファイルで上書きする

## 環境一覧

|環境|プロジェクト名|目的|起動|
|:--|:--|:--|:--|
|検証環境|my-devenv-recipe-testing|動作確認・デバッグ|`docker compose up`(compose.yaml + compose.override.yaml)|
|開発環境|my-devenv-recipe-development|コーディング作業|`devcontainer up`(compose.yaml + compose.override.yaml + .devcontainer/compose.devcontainer.yaml)|
|CI環境|my-devenv-recipe-ci|e2eテスト|`docker compose -f compose.yaml -f compose.ci.yaml up`|
|本番環境|my-devenv-recipe|secretsの適切な管理|`docker compose -f compose.yaml -f compose.production.yaml up`|
