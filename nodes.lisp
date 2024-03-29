;;;; Code related to nodes

(in-package #:dhticl)

(alexandria:define-constant +my-id+
  (octets-to-string
   (let ((array (make-array 20 :element-type '(unsigned-byte 8))))
     (dotimes (i 20 array)
       (setf (aref array i) (random 256)))))
  :test #'string=)

(defvar *node-list* (list))

(defstruct node
  (id nil :type string
          :read-only t)
  (ip)
  (port)
  (distance nil :read-only t)
  (last-activity nil :type fixnum)
  (health))

(defun create-node (&key (id nil) (ip nil) (port nil) (distance nil)
                      (last-activity nil)
                      (health :questionable))
  "Creates a node object with the specified attributes and adds it
to *NODE-LIST*."
  (let ((node (make-node :id id
                         :ip ip
                         :port port
                         :distance distance
                         :last-activity last-activity
                         :health health)))
    (push node *node-list*)
    node))

(defun calculate-node-distance (node)
  "Returns the distance between NODE and us."
  (calculate-distance (convert-id-to-int +my-id+)
                      (convert-id-to-int (node-id node))))

(defun calculate-elapsed-inactivity (node)
  "Returns the time in minutes since NODE's last seen activity."
  (and (node-last-activity node) (minutes-since last-activity)))

(defun calculate-node-health (node)
  "Returns the node's health as a keyword, either :GOOD, :QUESTIONABLE,
or :BAD."
  (let ((time-inactive (calculate-elapsed-inactivity node)))
    (cond ((null time-inactive) :questionable)
          ((< time-inactive 15) :good)
          (t :bad))))

(defun node-closer-p (goal node1 node2)
  "Returns T if NODE1 is closer to GOAL than NODE2, NIL otherwise."
  (let ((id1 (node-id node1))
        (id2 (node-id node2)))
    (< (calculate-distance (convert-id-to-int id1) goal)
       (calculate-distance (convert-id-to-int id2) goal))))

(defun compact-peer-info (node)
  "Translates NODE's IP and port into compact format."
  (format nil "~a~a"
          (octets-to-string (node-ip node))
          (octets-to-string (ironclad:integer-to-octets (node-port node)))))

(defun compact-node-info (node)
  "Translate's NODE's ID, IP, and port into compact peer format."
  (format nil "~a~a" (node-id node) (compact-peer-info node)))
