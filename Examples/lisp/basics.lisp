;; Lisp の基本

(defun fib (n)
  (if (< n 2)
      n
      (+ (fib (- n 1)) (fib (- n 2)))))

(defun square (x) (* x x))

(format t "fib: ~a~%" (mapcar #'fib '(0 1 2 3 4 5 6 7 8 9)))

(defvar *nums* '(5 3 9 1 7))
(format t "nums: ~a~%" *nums*)
(format t "sum: ~a~%" (reduce #'+ *nums*))
(format t "squares: ~a~%" (mapcar #'square *nums*))
(format t "big: ~a~%" (remove-if-not (lambda (x) (> x 3)) *nums*))
(format t "sorted: ~a~%" (sort (copy-list *nums*) #'<))
(format t "length: ~a~%" (length *nums*))
(format t "first: ~a rest: ~a~%" (car *nums*) (cdr *nums*))
(format t "reversed: ~a~%" (reverse *nums*))

(let ((total 0))
  (dolist (n *nums*)
    (setq total (+ total n)))
  (format t "total: ~a~%" total))

(dotimes (i 3)
  (format t "i = ~a~%" i))

(defun classify (n)
  (cond ((< n 0) "negative")
        ((= n 0) "zero")
        ((< n 10) "small")
        (t "large")))

(dolist (n '(-5 0 3 42))
  (format t "~a is ~a~%" n (classify n)))

(defun greet (name &optional greeting)
  (concatenate 'string (if greeting greeting "Hello") ", " name "!"))

(format t "~a~%" (greet "World"))
(format t "~a~%" (greet "Lisp" "Hi"))

(let ((table (make-hash-table)))
  (sethash "a" table 1)
  (sethash "b" table 2)
  (format t "a = ~a, count = ~a~%" (gethash "a" table) (hash-table-count table)))

(format t "upper: ~a~%" (string-upcase "hello, lisp"))
(format t "17 mod 5 = ~a~%" (mod 17 5))
(format t "2^10 = ~a~%" (expt 2 10))
(format t "nested: ~a~%" '(1 (2 3) (4 (5))))

(when (> 3 2) (format t "when works~%"))
(unless (> 2 3) (format t "unless works~%"))
