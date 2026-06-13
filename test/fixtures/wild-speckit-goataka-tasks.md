# タスク: 勤怠管理システム

**入力**: `/specs/20251222-114347794740791/` からの設計ドキュメント
**前提条件**: plan.md (必須), spec.md (ユーザーストーリー用に必須), research.md, data-model.md, contracts/

**テスト**: Cucumber + Playwright for E2E, Vitest for Unit

**組織化**: タスクはユーザーストーリーごとにグループ化され、各ストーリーの独立した実装とテストを可能にします。

## フォーマット: `[ID] [P?] [Story] 説明`

- **[P]**: 並行実行可能 (異なるファイル、依存関係なし)
- **[Story]**: どのユーザーストーリーに属するか (例: US1, US2, US3)
- 説明に正確なファイルパスを含める

## Phase 1: インフラ・セットアップ (AWS + モノレポ)

**目的**: AWSサーバレス構成とモノレポ基盤の構築

- [ ] T001 AWS CDKでインフラ定義作成 (infrastructure/cdk/)
- [ ] T001.1 GitHub OIDCプロバイダー設定 (各AWSアカウント)
- [ ] T001.2 GitHub Actions用IAMロール作成 (OIDC認証用)
- [ ] T002 Turborepo設定とワークスペース初期化
- [ ] T003 AWS Cognito User Pool設定
- [ ] T004 DynamoDBテーブル作成 (packages/database/)
- [ ] T005 NestJS + Lambdaプロジェクト初期化 (apps/backend/)
- [ ] T006 React + Viteプロジェクト初期化 (apps/frontend/)
- [ ] T007 React + Vite製品サイト初期化 (apps/website/)
- [ ] T008 共有パッケージ設定 (packages/shared/, packages/config/)

## ユーザーストーリー 1: 勤怠記録機能 (P1)

**目的**: 従業員が勤務時間を記録し、管理者が勤怠データを確認できる

- [ ] T101 [P] US1 NestJS勤怠モジュール作成 (apps/backend/src/modules/attendance/)
- [ ] T102 [P] US1 DynamoDB勤怠サービス実装 (apps/backend/src/modules/attendance/attendance.service.ts)
- [ ] T103 US1 出勤API実装 (/api/attendance/check-in)
- [ ] T104 US1 退勤API実装 (/api/attendance/check-out)
- [ ] T105 US1 打刻記録取得API実装 (/api/attendance/clocks)
- [ ] T106 US1 React勤怠記録コンポーネント作成 (apps/frontend/src/components/attendance/)
- [ ] T107 US1 管理者勤怠管理UI実装 (apps/frontend/src/pages/admin/attendance/)
- [ ] T108 US1 勤務時間計算ユーティリティ実装 (packages/shared/src/utils/attendance.ts)
- [ ] T110 US1 勤怠データバリデーション実装 (packages/shared/src/validation/attendance.ts)

## ユーザーストーリー 2: 製品サイトとサポート (P2)

**目的**: 製品の紹介とサポート情報を提供

- [ ] T201 [P] US2 製品紹介ページ作成 (apps/website/src/pages/product/index.tsx - 静的サイト)
- [ ] T202 [P] US2 サポートサイト静的ページ作成 (apps/website/src/pages/support/ - FAQ, ドキュメント)
- [ ] T203 US2 リリースノートページ作成 (apps/website/src/pages/releases/ - 静的サイト)
- [ ] T207 US2 リリースノート自動生成スクリプト作成 (tools/scripts/generate-release-notes.js)

## ユーザーストーリー 3: 多言語対応 (P3)

**目的**: 日本語と英語の両言語をサポート

- [ ] T301 [P] US3 React i18n設定 (apps/frontend/src/i18n/)
- [ ] T302 [P] US3 日本語翻訳ファイル作成 (apps/frontend/src/locales/ja.json)
- [ ] T303 [P] US3 英語翻訳ファイル作成 (apps/frontend/src/locales/en.json)
- [ ] T304 US3 言語切り替えコンポーネント実装 (packages/shared/src/components/LanguageSwitcher.tsx)
- [ ] T305 US3 すべてのUIテキストを多言語対応に更新

## Phase 4: 統合・テスト・デプロイ

**目的**: 全機能の統合、テスト、デプロイ

- [ ] T401 レスポンシブデザイン実装 (最低1280x1024, 推奨1920x1080以上)
- [ ] T402 AWS Lambda関数デプロイ設定 (serverless.yml)
- [ ] T403 API Gateway設定とCORS対応
- [ ] T404 S3 + CloudFront静的ホスティング設定
- [ ] T405 ユニットテスト実装 (Vitest)
- [ ] T406 E2Eテスト実装 (Cucumber + Playwright)
- [ ] T407 CI/CDパイプライン設定 (.github/workflows/ci.yml)
- [ ] T408 パフォーマンス最適化 (Lambda Provisioned Concurrency)
- [ ] T409 セキュリティ監査と設定
- [ ] T410 ドキュメント完成とREADME更新

## 依存関係マップ

```
T001-T008 → T101-T110, T201-T207, T301-T305 → T401-T410
T101-T102 → T103-T105
T103-T105 → T106-T107
T106-T107 → T108-T110
T201-T203 → T204-T207
T301-T303 → T304 → T305
```

## テスト要件

⚠️ **テストは実装前に作成**: BDDアプローチでCucumberを使用

### E2Eテストシナリオ (Cucumber)

**勤怠記録機能**:
```gherkin
Feature: 勤怠記録機能
  Scenario: 従業員が出勤・退勤を記録できる
    Given 従業員がログインしている
    When 出勤ボタンをクリックする
    Then 出勤時間が記録される
    When 退勤ボタンをクリックする
    Then 退勤時間が記録され勤務時間が計算される
```

**管理者機能**:
```gherkin
Feature: 管理者勤怠管理
  Scenario: 管理者が打刻記録を閲覧できる
    Given 管理者がログインしている
    When 勤怠管理画面にアクセスする
    Then 全従業員の打刻記録が表示される
```

### ユニットテスト

- Service層のビジネスロジックテスト
- Utility関数のテスト
- Validationロジックのテスト
- APIレスポンスのテスト

## タスクは既に定義済み

上記のユーザーストーリーセクションを参照してください。

## ユーザーストーリー 3: 多言語対応 (P3)

**目的**: 日本語と英語の両言語をサポート

- [ ] T301 [P] US3 react-i18nextを設定して多言語対応
- [ ] T302 [P] US3 日本語翻訳ファイルを作成 (apps/*/src/messages/ja.json)
- [ ] T303 [P] US3 英語翻訳ファイルを作成 (apps/*/src/messages/en.json)
- [ ] T304 US3 言語切り替えコンポーネントを実装 (packages/shared/src/components/LanguageSwitcher.tsx)
- [ ] T305 US3 すべてのUIテキストを多言語対応に更新

## Phase 4: 統合とテスト

**目的**: 全機能の統合と品質保証

- [ ] T401 レスポンシブデザインを実装 (最低1280x1024, 推奨1920x1080以上)
- [ ] T402 ブラウザ互換性をテスト (Chrome, Firefox, Safari, Edge)
- [ ] T403 パフォーマンス最適化 (API <500ms, ページロード <3秒)
- [ ] T404 セキュリティ監査を実施 (AWSセキュリティベストプラクティス)
- [ ] T405 APIテストスイート実行 (Vitest + Supertest)
- [ ] T406 Reactコンポーネントテスト実行 (React Testing Library)
- [ ] T407 E2Eテスト実行 (Cucumber + Playwright)
- [ ] T408 統合テスト実行 (NestJS e2e)
- [ ] T409 リリースノート生成と公開
- [ ] T410 製品サイト・サポートサイトの最終確認

## 依存関係マップ

```
T001 → T002 → T003 → T004,T005,T006,T007
T101,T102 → T103,T104,T105
T103,T104 → T106,T107
T106 → T108,T109,T110
T201,T202 → T203,T204
T203 → T205,T206,T207
T301 → T302,T303 → T304 → T305
T101-T110,T201-T207,T301-T305 → T401-T406
```

## テスト要件

⚠️ **テストは実装前に作成**: 以下のテストは実装前に作成し、テスト駆動開発を行う

- [ ] TT001 US1 勤怠記録APIの単体テスト (Vitest + Supertest)
- [ ] TT002 US1 勤怠記録UIのコンポーネントテスト (React Testing Library)
- [ ] TT004 US3 多言語切り替えのコンポーネントテスト (React Testing Library)
- [ ] TT005 API統合テスト (NestJS e2eテスト)
- [ ] TT006 Reactコンポーネントテストスイート (全コンポーネント)