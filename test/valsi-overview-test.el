;;; valsi-overview-test.el --- Overview grammar regression tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Samuel Schmidt
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; Regression tests for issue #57: badge and parenthesized links, tilde
;; and long fences, follow-at-point, and fence-aware section navigation.

;;; Code:

(require 'ert)
(require 'valsi-overview)

(defun valsi-overview-test--links (text)
  "Return (LABEL TARGET) for each link node of TEXT's overview parse."
  (mapcar (lambda (n) (list (valsi-node-prop n :label)
                            (valsi-node-prop n :target)))
          (valsi-node-of-type (valsi-overview-parse text) 'link)))

(defun valsi-overview-test--titles (text)
  "Return the section titles of TEXT's overview parse."
  (mapcar (lambda (n) (valsi-node-prop n :title))
          (valsi-node-of-type (valsi-overview-parse text) 'section)))

(ert-deftest valsi-overview-test-badge-link ()
  "A badge link is one link to its outer target."
  (should (equal '(("![Build](https://x/b.svg)" "https://ci.example"))
                 (valsi-overview-test--links
                  "# D\n\n[![Build](https://x/b.svg)](https://ci.example)\n"))))

(ert-deftest valsi-overview-test-parenthesized-target ()
  "A target containing balanced parentheses is kept whole."
  (should (equal '(("w" "https://en.wikipedia.org/wiki/Foo_(bar)"))
                 (valsi-overview-test--links
                  "# D\n\n[w](https://en.wikipedia.org/wiki/Foo_(bar))\n")))
  (should (equal '(("a" "a.md") ("b" "b.md"))
                 (valsi-overview-test--links
                  "See [a](a.md) and [b](b.md).\n")))
  (let* ((text "x [a](a.md) y\n")
         (link (car (valsi-node-of-type (valsi-overview-parse text) 'link))))
    (should (equal "[a](a.md)" (substring text (valsi-node-beg link)
                                          (valsi-node-end link))))))

(ert-deftest valsi-overview-test-tilde-fence ()
  "Headings inside a tilde fence are not sections."
  (let ((text "# D\n\n~~~\n# not heading\n~~~\n"))
    (should (equal '("D") (valsi-overview-test--titles text)))
    (should (= 1 (length (valsi-node-of-type (valsi-overview-parse text)
                                             'codeblock))))))

(ert-deftest valsi-overview-test-long-fence ()
  "A four-backtick fence around a three-backtick example is one block."
  (let* ((text "# D\n\n````md\n```sh\n# x\n```\n````\n## After\n")
         (root (valsi-overview-parse text))
         (blocks (valsi-node-of-type root 'codeblock)))
    (should (= 1 (length blocks)))
    (should (equal "md" (valsi-node-prop (car blocks) :lang)))
    (should (equal '("D" "After") (valsi-overview-test--titles text)))))

(ert-deftest valsi-overview-test-follow-at-point ()
  "Follow uses the link under point, not the first on the line."
  (with-temp-buffer
    (insert "See [a](a.md) and [b](b.md).")
    (let ((inhibit-message t))
      (goto-char (point-min))
      (search-forward "[b")
      (should (equal "Link target: b.md" (valsi-overview-follow)))
      (goto-char (point-min))
      (search-forward "[a")
      (should (equal "Link target: a.md" (valsi-overview-follow)))
      (goto-char (point-min))
      (should (equal "No link at point" (valsi-overview-follow))))))

(ert-deftest valsi-overview-test-section-navigation-skips-fences ()
  "Section navigation ignores `#' lines inside code fences."
  (with-temp-buffer
    (insert "# T\n\nx\n\n```sh\n# shell comment\n```\n## Next\n")
    (goto-char (point-min))
    (forward-line 2)
    (let ((inhibit-message t))
      (valsi-overview-next-section)
      (should (looking-at-p "## Next"))
      (valsi-overview-previous-section)
      (should (looking-at-p "# T")))))

(provide 'valsi-overview-test)
;;; valsi-overview-test.el ends here
