# Real-world spec-kit tasks.md fragment

From hashrocket.com "From Spec to Shipping" (real Rails project,
specs/001-remove-the-team/tasks.md, 23 tasks generated; only these lines
quoted verbatim in the post):

- [ ] T001 [P] [US1] Verify header template contains Team link at `app/views/layouts/_header.html.haml:10`
- [ ] T004 [US1] Create feature spec file at `spec/features/visitor_views_navigation_spec.rb`
- [ ] T016 [P] [US1] Manual verification: Start server and verify header on homepage (desktop viewport)

Observations vs. the template:
- Generated tasks keep the `[ID] [P?] [Story]` line grammar exactly.
- Descriptions carry backticked repo paths, sometimes with line numbers.
- Non-code tasks ("Manual verification: ...") use a `Kind:` style prefix in prose.

<!-- Valsi corpus note: collected 2026-07-10. -->
