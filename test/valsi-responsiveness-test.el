;;; valsi-responsiveness-test.el --- Interactive regression tests -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:
;; Verify work avoided on hot paths, cache freshness, and direct interaction.
;; Operation counts are stable across machines; timings live in the benchmark.

;;; Code:

(require 'ert)
(require 'valsi)
(require 'valsi-test-refresh)

(defun valsi-responsiveness--chain (count &optional cycle)
  "Return a COUNT-task dependency chain, closing a cycle when CYCLE is non-nil."
  (concat "# Plan\n"
          (mapconcat
           (lambda (id)
             (format "- [ ] T%03d Task%s\n" id
                     (if (and (= id 1) (not cycle)) ""
                       (format " (depends on T%03d)"
                               (if (= id 1) count (1- id))))))
           (number-sequence 1 count) "")))

(ert-deftest valsi-responsiveness-nested-task-states ()
  "Deep completed hierarchies do bounded work when linted or inspected."
  (let* ((tree (valsi-plan-parse
                (mapconcat
                 (lambda (n) (format "%s- [x] Nested task\n"
                                     (make-string (* 2 n) ?\s)))
                 (number-sequence 0 39) "")))
         (task (car (valsi-node-of-type tree 'task)))
         (property (symbol-function 'valsi-node-prop))
         (reads 0))
    (cl-letf (((symbol-function 'valsi-node-prop)
               (lambda (&rest args)
                 (cl-incf reads)
                 (when (> reads 10000)
                   (ert-fail "Repeatedly traversed completed descendants"))
                 (apply property args))))
      (should (eq 'done (valsi-plan-effective-state task)))
      (should-not (valsi-plan--lint-collect tree))
      (should (equal '(1 1 0) (valsi-plan--leaf-stats tree))))))

(ert-deftest valsi-responsiveness-progress-counts-leaves ()
  "Progress counts actual work once and derives parent states from leaf tasks."
  (let* ((tree (valsi-plan-parse
                (concat "- [x] T001 Parent\n"
                        "  - [x] T001.1 Completed\n"
                        "  - [-] T001.2 Active\n"
                        "  - [x] T001.3 Marked done prematurely\n"
                        "    - [ ] T001.3.1 Open\n"
                        "- [c] T002 Cancelled\n"
                        "- [?] T003 Unknown\n")))
         (tasks (valsi-node-of-type tree 'task)))
    (should (equal '(1 5 1) (valsi-plan--leaf-stats tree)))
    (should (equal '(in-progress done in-progress open open cancelled unknown)
                   (mapcar #'valsi-plan-effective-state tasks)))
    (should (equal '(0 0 0) (valsi-plan--leaf-stats (valsi-plan-parse "# Empty\n"))))
    (should (equal '("T001: marked done but has an unfinished child"
                     "T001.3: marked done but has an unfinished child"
                     "T003: unknown state char \"?\"")
                   (valsi-plan--lint-issues tree)))))

(ert-deftest valsi-responsiveness-actionable-uses-derived-parent-state ()
  "A parent's completed children satisfy dependencies even if its box is open."
  (with-temp-buffer
    (insert (concat "- [ ] T001 Parent (depends on missing)\n"
                    "  - [x] T001.1 Completed\n"
                    "- [ ] T002 Next (depends on T001)\n"))
    (let ((tree (valsi-node-shift (valsi-plan-parse (buffer-string)) 1)))
      (cl-letf (((symbol-function 'valsi-tree) (lambda () tree)))
        (should (equal "T002" (valsi-node-prop (valsi-plan-next-actionable) :id)))
        (should (looking-at "- \\[ \\] T002"))))))

(ert-deftest valsi-responsiveness-long-dependencies ()
  "Long chains and cycles lint completely without recursive graph traversal."
  (let ((max-lisp-eval-depth 100))
    (should-not (valsi-plan--lint-collect
                 (valsi-plan-parse (valsi-responsiveness--chain 2000))))
    (let* ((tree (valsi-plan-parse (valsi-responsiveness--chain 2000 t)))
           (tasks (valsi-node-of-type tree 'task))
           (findings (valsi-plan--lint-collect tree)))
      (should (= 2000 (length findings)))
      (should (seq-every-p
               (lambda (finding) (string-suffix-p "dependency cycle" (cdr finding)))
               findings))
      (should (valsi-plan--reaches-p "T2000" "T001" tasks))
      (should-not (valsi-plan--reaches-p "T2000" "missing" tasks)))))

(ert-deftest valsi-responsiveness-cycle-membership ()
  "Only members of cycles are flagged, including self edges and duplicates."
  (let* ((tree (valsi-plan-parse
                (concat "- [ ] T001 (depends on T002)\n"
                        "- [ ] T002 (depends on T003)\n"
                        "- [ ] T003 (depends on T002, T004)\n"
                        "- [ ] T004 Leaf\n"
                        "- [ ] T005 (depends on T005)\n"
                        "- [ ] T006 (depends on T999)\n"
                        "- [ ] T004 (depends on T004)\n")))
         (issues (valsi-plan--lint-issues tree)))
    (should (equal (seq-filter (lambda (s) (string-suffix-p "dependency cycle" s))
                               issues)
                   '("T002: dependency cycle" "T003: dependency cycle"
                     "T005: dependency cycle")))
    (should (member "T006: dangling dep T999" issues))
    (should (member "duplicate id T004 (2)" issues))))

(ert-deftest valsi-responsiveness-sync-once-and-idle-edit ()
  "Opening and refreshing parse once; typing waits for idle, queries stay fresh."
  (valsi-init)
  (with-temp-buffer
    (insert "# Plan\n- [ ] T001 First\n")
    (setq buffer-file-name "/tmp/valsi-responsive/PLAN.md")
    (let ((parse (symbol-function 'valsi-registry-parse-content))
          (count 0)
          (valsi-app-auto-sidebar nil))
      (cl-letf (((symbol-function 'valsi-registry-parse-content)
                 (lambda (&rest args) (cl-incf count) (apply parse args))))
        (unwind-protect
            (progn
              (valsi-artifact-minor-mode 1)
              (should (= count 1))
              (valsi-tree)
              (should (= count 1))
              (valsi-refresh)
              (should (= count 2))
              (valsi-enter-insert)
              (goto-char (point-max))
              (insert "- [ ] T002 ")
              (insert "Second\n")
              (should (= count 2))
              (should (timerp valsi--refresh-timer))
              (valsi--cancel-refresh)
              (valsi--idle-refresh (current-buffer))
              (should (= count 3))
              (should (= 2 (length (valsi-node-of-type (valsi-tree) 'task))))
              (let ((tree valsi--tree))
                (put-text-property (point-min) (point-max) 'face 'bold)
                (should (eq tree (valsi-tree)))
                (should (= count 3)))
              (insert "- [ ] T003 Third\n")
              (should (= 3 (length (valsi-node-of-type (valsi-tree) 'task))))
              (should (= count 4)))
          (valsi-artifact-minor-mode -1)
          (should-not valsi--refresh-timer))))))

(ert-deftest valsi-responsiveness-narrowed-artifact ()
  "Narrowing does not truncate AAP documents or shift their coordinates."
  (valsi-init)
  (with-temp-buffer
    (insert "# Plan\n- [ ] T001 First\n- [ ] T002 Second\n")
    (setq buffer-file-name "/tmp/valsi-narrowed/PLAN.md")
    (goto-char (point-min))
    (forward-line 2)
    (let ((second (point)))
      (narrow-to-region second (point-max))
      (unwind-protect
          (progn
            (valsi-artifact-minor-mode 1)
            (let ((tasks (valsi-node-of-type (valsi-tree) 'task)))
              (should (= 2 (length tasks)))
              (should (= second (valsi-node-beg (cadr tasks))))))
        (valsi-artifact-minor-mode -1)))))

(ert-deftest valsi-responsiveness-browse-toggle-and-read-only ()
  "Semantic toggles work in Browse while preexisting read-only stays protected."
  (valsi-init)
  (dolist (read-only '(nil t))
    (with-temp-buffer
      (insert "- [ ] T001 First\n")
      (goto-char (point-min))
      (setq buffer-file-name "/tmp/valsi-toggle/PLAN.md"
            buffer-read-only read-only)
      (unwind-protect
          (progn
            (valsi-artifact-minor-mode 1)
            (should (eq (key-binding (kbd "t")) #'valsi-toggle))
            (if read-only
                (should-error (valsi-toggle) :type 'buffer-read-only)
              (call-interactively (key-binding (kbd "t")))
              (should (string-match-p "\\[-\\]" (buffer-string)))
              (should buffer-read-only)
              (should valsi-browse-mode)))
        (valsi-artifact-minor-mode -1)))))

(ert-deftest valsi-responsiveness-scan-cache-freshness ()
  "Scans reuse trees but observe buffer, disk, file-set, and grammar changes."
  (valsi-init)
  (let* ((root (file-name-as-directory (make-temp-file "valsi-scan-" t)))
         (file (expand-file-name "PLAN.md" root))
         (files (list file))
         (parse (symbol-function 'valsi-registry-parse-content))
         (count 0)
         buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'valsi-app--project-candidates) (lambda (_) files))
                  ((symbol-function 'valsi-registry-parse-content)
                   (lambda (&rest args) (cl-incf count) (apply parse args))))
          (with-temp-file file (insert "- [ ] T001 First\n"))
          (should (equal "1 open" (plist-get (car (valsi-app--scan root)) :summary)))
          (should (= count 1))
          (valsi-app--scan root)
          (should (= count 1))
          (with-temp-file file (insert "- [x] T001 First done\n"))
          (should (equal "1 done" (plist-get (car (valsi-app--scan root)) :summary)))
          (should (= count 2))
          (setq buffer (find-file-noselect file))
          (with-current-buffer buffer
            (goto-char (point-max))
            (insert "- [ ] T002 Unsaved\n"))
          (should (equal "1 open · 1 done"
                         (plist-get (car (valsi-app--scan root)) :summary)))
          (should (= count 3))
          (with-current-buffer buffer (narrow-to-region 1 2))
          (valsi-app--scan root)
          (should (= count 3))
          (valsi-registry-register (valsi-registry-get 'plan))
          (should (equal "1 open · 1 done"
                         (plist-get (car (valsi-app--scan root)) :summary)))
          (should (= count 4))
          (setq files nil)
          (should-not (valsi-app--scan root))
          (should (= 0 (hash-table-count
                        (valsi-app-live-refresh--project-cache
                         (valsi-app-live-refresh--project root))))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (valsi-app-live-refresh-reset root)
      (delete-directory root t))))

(ert-deftest valsi-responsiveness-cached-plan-observes-reference-changes ()
  "A referenced file changing makes a cached plan stale without reparsing."
  (valsi-init)
  (let* ((root (file-name-as-directory (make-temp-file "valsi-stale-" t)))
         (file (expand-file-name "PLAN.md" root))
         (target (expand-file-name "code.el" root)))
    (unwind-protect
        (cl-letf (((symbol-function 'valsi-app--project-candidates)
                   (lambda (_) (list file))))
          (with-temp-file target (insert "old"))
          (with-temp-file file (insert "- [x] T001 Edit `./code.el`\n"))
          (set-file-times target (time-subtract (current-time) 60))
          (should (= 0 (plist-get (car (valsi-app--scan root)) :stale)))
          (set-file-times target (time-add (current-time) 60))
          (cl-letf (((symbol-function 'valsi-registry-parse-content)
                     (lambda (&rest _) (ert-fail "Unchanged plan reparsed"))))
            (should (= 1 (plist-get (car (valsi-app--scan root)) :stale)))))
      (valsi-app-live-refresh-reset root)
      (delete-directory root t))))

(ert-deftest valsi-responsiveness-hub-reentry-keeps-place ()
  "Reentering a hub preserves its filter, folds, and selected row."
  (let* ((root (file-name-as-directory (make-temp-file "valsi-hub-" t)))
         hub)
    (unwind-protect
        (cl-letf (((symbol-function 'valsi-app--scan) (lambda (_) nil)))
          (setq hub (valsi-app--buffer root nil))
          (with-current-buffer hub
            (setq valsi-app--filter "plan")
            (goto-char (point-min))
            (re-search-forward "^[▾▸] Artifacts")
            (beginning-of-line)
            (valsi-view-toggle-section))
          (should (eq hub (valsi-app--buffer root nil)))
          (with-current-buffer hub
            (should (equal "plan" valsi-app--filter))
            (should-not (valsi-view-section-expanded-p 'artifacts t))
            (should (equal "section:artifacts"
                           (get-text-property (point) 'valsi-row-id)))))
      (when (buffer-live-p hub) (kill-buffer hub))
      (valsi-app-live-refresh-reset root)
      (delete-directory root t))))

(ert-deftest valsi-responsiveness-sidebar-defers-discovery ()
  "Showing context must not perform a project scan on the window hook."
  (let* ((root (file-name-as-directory (make-temp-file "valsi-sidebar-" t)))
         sidebar)
    (unwind-protect
        (cl-letf (((symbol-function 'valsi-app--scan)
                   (lambda (_) (ert-fail "Synchronous sidebar scan"))))
          (with-temp-buffer
            (setq sidebar (valsi-app--buffer root t (current-buffer))))
          (should (timerp (valsi-app-live-refresh--project-timer
                           (valsi-app-live-refresh--project root)))))
      (when (buffer-live-p sidebar) (kill-buffer sidebar))
      (valsi-app-live-refresh-reset root)
      (delete-directory root t))))

(ert-deftest valsi-responsiveness-dispatch-shares-snapshot ()
  "Hub and sidebar see the same new-file state from a single scan per event."
  (let* ((root (file-name-as-directory (make-temp-file "valsi-dispatch-" t)))
         (file (expand-file-name "PLAN.md" root))
         (hub (generate-new-buffer " *valsi-hub-test*"))
         (sidebar (generate-new-buffer " *valsi-sidebar-test*"))
         (scans 0))
    (unwind-protect
        (cl-letf (((symbol-function 'valsi-app--project-candidates)
                   (lambda (_)
                     (cl-incf scans)
                     (list file))))
          (valsi-app-live-refresh-reconcile root nil)
          (with-temp-file file (insert "# Plan\n"))
          (dolist (buffer (list hub sidebar))
            (with-current-buffer buffer
              (valsi-app-mode)
              (setq valsi-app--root root)
              (valsi-app-live-refresh-subscribe
               buffer root #'valsi-app--accept-snapshot #'valsi-app--scan-project-steps)))
          (valsi-app-live-refresh--dispatch (valsi-app-live-refresh--project root))
          (valsi-test-refresh-drain root)
          (should (= 1 scans))
          (dolist (buffer (list hub sidebar))
            (should (equal "new" (plist-get
                                  (car (buffer-local-value 'valsi-app--entries buffer))
                                  :state)))))
      (kill-buffer hub)
      (kill-buffer sidebar)
      (valsi-app-live-refresh-reset root)
      (delete-directory root t))))

(ert-deftest valsi-responsiveness-edit-refresh-is-incremental ()
  "Buffer edits update their own row without project discovery or other reads."
  (valsi-init)
  (let* ((root (file-name-as-directory (make-temp-file "valsi-incremental-" t)))
         (one (expand-file-name "PLAN.md" root))
         (two (expand-file-name "README.md" root))
         (files (list one two))
         (discoveries 0)
         (reads nil)
         (read-file (symbol-function 'valsi-app--file-text))
         buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'valsi-app--project-candidates)
                   (lambda (_) (cl-incf discoveries) files))
                  ((symbol-function 'valsi-app--file-text)
                   (lambda (file) (push file reads) (funcall read-file file))))
          (with-temp-file one (insert "- [ ] T001 First\n"))
          (with-temp-file two (insert "# Overview\n"))
          (setq buffer (find-file-noselect one))
          (valsi-app--scan root)
          (setq reads nil)
          (with-current-buffer buffer
            (goto-char (point-max))
            (insert "- [ ] T002 Second\n"))
          (let* ((valsi-app-live-refresh-changed-files (list one))
                 (entries (valsi-app--scan root)))
            (should (= 1 discoveries))
            (should (equal reads (list one)))
            (should (= 2 (length entries)))
            (should (equal "2 open" (plist-get (car entries) :summary))))
          ;; A grammar reload invalidates every entry even during an edit event.
          (valsi-registry-register (valsi-registry-get 'plan))
          (setq reads nil)
          (let ((valsi-app-live-refresh-changed-files (list one)))
            (valsi-app--scan root))
          (should (= 2 discoveries))
          (should (= 2 (length reads)))
          ;; Missing a notification must not hide another artifact's disk edit.
          (with-temp-file two (insert "# Changed overview on disk\n"))
          (setq reads nil)
          (let ((valsi-app-live-refresh-changed-files (list one)))
            (valsi-app--scan root))
          (should (= 3 discoveries))
          (should (equal reads (list two))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (valsi-app-live-refresh-reset root)
      (delete-directory root t))))

(ert-deftest valsi-responsiveness-observer-lifecycle ()
  "Fontification does not schedule scans and closed hubs stop observing edits."
  (let* ((root (file-name-as-directory (make-temp-file "valsi-observe-" t)))
         (file (expand-file-name "PLAN.md" root))
         (hub (generate-new-buffer " *valsi-observer-test*"))
         buffer)
    (unwind-protect
        (progn
          (with-temp-file file (insert "# Plan\n"))
          (setq buffer (find-file-noselect file))
          (valsi-app-live-refresh-subscribe hub root #'ignore)
          (valsi-app-live-refresh-reconcile root (list (list :file file)))
          (let ((project (valsi-app-live-refresh--project root)))
            (with-current-buffer buffer
              (put-text-property 1 2 'face 'bold)
              (should-not (valsi-app-live-refresh--project-timer project))
              (insert "text")
              (should (equal (list file)
                             (valsi-app-live-refresh--project-changed-files project))))
            ;; A later disk event must upgrade the pending incremental scan.
            (valsi-app-live-refresh-schedule root)
            (should (valsi-app-live-refresh--project-rescan project))
            (valsi-app-live-refresh-unsubscribe hub root)
            (should-not (valsi-app-live-refresh--project-timer project))
            (with-current-buffer buffer
              (should-not valsi-app-live-refresh--buffer-root)
              (insert "more"))
            (should-not (valsi-app-live-refresh--project-timer project))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (kill-buffer hub)
      (valsi-app-live-refresh-reset root)
      (delete-directory root t))))

(ert-deftest valsi-responsiveness-sidebar-follows-buffer-switch ()
  "Switching artifacts retargets an existing sidebar without a per-key lookup."
  (let ((source (generate-new-buffer " *valsi-source*"))
        (old-source (generate-new-buffer " *valsi-old-source*"))
        (sidebar (generate-new-buffer " *valsi-context*")))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer source)
          (setq-local valsi-artifact-minor-mode t)
          (setq-local valsi--tree (valsi-node-create :beg 1 :end 1))
          (setq-local buffer-file-name "/tmp/valsi-context/PLAN.md")
          (setq-local valsi-app--sidebar-buffer sidebar)
          (with-current-buffer sidebar
            (valsi-app-mode)
            (setq valsi-app--compact t valsi-app--source-buffer old-source))
          (display-buffer-in-side-window sidebar '((side . right)))
          (let ((renders 0))
            (cl-letf (((symbol-function 'frame-width) (lambda (&optional _) 140))
                      ((symbol-function 'valsi-app--root)
                       (lambda () (ert-fail "Project lookup during navigation")))
                      ((symbol-function 'valsi-app--render) (lambda () (cl-incf renders))))
              (should (eq source (valsi-app--sync-chrome (selected-frame))))
              (valsi--update-sidebar-context)
              (should (eq source (buffer-local-value 'valsi-app--source-buffer sidebar)))
              (should (= renders 1))
              (setq valsi--tree nil)
              (valsi--update-sidebar-context)
              (should (= renders 1))
              (let ((signature (valsi-app-context-signature source)))
                (insert "edit")
                (should-not (equal signature (valsi-app-context-signature source)))))))
      (kill-buffer source)
      (kill-buffer old-source)
      (kill-buffer sidebar))))

(ert-deftest valsi-responsiveness-context-includes-plan-dependencies ()
  "The sidebar exposes dependencies from the plan grammar's actual property."
  (let ((source (generate-new-buffer " *valsi-dep-source*")))
    (unwind-protect
        (progn
          (with-current-buffer source
            (insert "- [ ] T002 Second (depends on T001)\n")
            (setq valsi--tree (valsi-node-shift
                               (valsi-plan-parse (buffer-string)) 1))
            (goto-char (point-min)))
          (with-temp-buffer
            (setq valsi-app--source-buffer source)
            (should (equal '("T001") (plist-get (valsi-app--context) :dependencies)))))
      (kill-buffer source))))

(ert-deftest valsi-responsiveness-lazy-fontification-preserves-text ()
  "Lazy fontification applies and removes artifact faces without changing text."
  (with-temp-buffer
    (insert "- [ ] T001 First\n")
    (setq-local font-lock-defaults '(nil t))
    (let ((font-lock-mode t)
          (original (buffer-string))
          (ensure (symbol-function 'font-lock-ensure)))
      (cl-letf (((symbol-function 'font-lock-ensure)
                 (lambda (&rest _) (ert-fail "Eager whole-buffer fontification"))))
        (valsi-view-set-font-lock valsi-plan-font-lock-keywords))
      (funcall ensure)
      (should (get-text-property 4 'face))
      (valsi-view-set-font-lock nil)
      (funcall ensure)
      (should-not (get-text-property 4 'face))
      (should (equal original (buffer-substring-no-properties (point-min) (point-max)))))))

(ert-deftest valsi-responsiveness-hub-workflow ()
  "Open, toggle, return, hand off, and edit an artifact through the hub keys."
  (valsi-init)
  (let* ((root (file-name-as-directory (make-temp-file "valsi-workflow-" t)))
         (file (expand-file-name "PLAN.md" root))
         (valsi-global-mode nil)
         (valsi-app-auto-sidebar nil)
         hub source row reference)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (with-temp-file file (insert "# Plan\n- [ ] T001 First\n"))
          (cl-letf (((symbol-function 'valsi-app--root) (lambda () root))
                    ((symbol-function 'valsi-app--project-candidates) (lambda (_) (list file)))
                    ((symbol-function 'valsi-terminal-agent-insert)
                     (lambda (text &optional _) (setq reference text))))
            (setq hub (valsi))
            (valsi-test-refresh-drain root)
            (goto-char (point-min))
            (execute-kbd-macro (kbd "n RET n"))
            (setq row (get-text-property (line-beginning-position) 'valsi-row-id))
            (should (equal row (concat "file:family:" file)))
            (execute-kbd-macro (kbd "RET"))
            (setq source (current-buffer))
            (should (equal buffer-file-name file))
            (should valsi-artifact-minor-mode)
            (should (eq valsi--interaction-state 'browse))
            (execute-kbd-macro (kbd "n t c"))
            (valsi-test-refresh-drain root)
            (should (eq hub (current-buffer)))
            ;; New Active and Attention rows above must not move this selection.
            (should (equal row (get-text-property (line-beginning-position) 'valsi-row-id)))
            (end-of-line)
            (execute-kbd-macro (kbd "@"))
            (should (equal (concat "@artifact:" file) reference))
            (execute-kbd-macro (kbd "i"))
            (should (eq source (current-buffer)))
            (should (eq valsi--interaction-state 'insert))
            (should (string-match-p "\\[-\\]" (buffer-string)))
            (execute-kbd-macro (kbd "<escape>"))
            (should (eq valsi--interaction-state 'browse))))
      (when-let* ((buffer (get-file-buffer file)))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (when (buffer-live-p hub) (kill-buffer hub))
      (valsi-app-live-refresh-reset root)
      (delete-directory root t))))

(ert-deftest valsi-responsiveness-attention-rows-are-actionable ()
  "Attention rows open their own files and the overflow exposes hidden rows."
  (with-temp-buffer
    (valsi-app-mode)
    (setq valsi-app--root default-directory
          valsi-app--entries
          (mapcar (lambda (n) (list :file (expand-file-name (format "PLAN%d.md" n))
                                   :grammar 'plan :state "modified"))
                  '(1 2 3 4)))
    (cl-letf (((symbol-function 'valsi-app--layout) (lambda (&optional _) 'narrow)))
      (valsi-app--render)
      (goto-char (point-min))
      (search-forward "modified")
      ;; Find the specific Attention row rather than a summary in Overview.
      (goto-char (point-min))
      (let* ((file (plist-get (car valsi-app--entries) :file))
             (row (text-property-search-forward 'valsi-row-id
                                                (concat "attention:" file) #'equal))
             visited)
        (should row)
        (goto-char (prop-match-beginning row))
        (end-of-line)
        (should (equal file (valsi-app--artifact-file-at-point)))
        (cl-letf (((symbol-function 'find-file) (lambda (target) (setq visited target)))
                  ((symbol-function 'valsi--maybe-enable) #'ignore))
          (valsi-app-activate))
        (should (equal visited file)))
      (goto-char (point-min))
      (search-forward "RET shows all")
      (valsi-app-activate)
      (should valsi-app--show-all-attention)
      (goto-char (point-min))
      (should (text-property-search-forward
               'valsi-row-id (concat "attention:" (plist-get (nth 3 valsi-app--entries) :file))
               #'equal)))))

(provide 'valsi-responsiveness-test)
;;; valsi-responsiveness-test.el ends here
