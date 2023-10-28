(in-package #:dhticl)

(defvar *default-port* 6881)

(defvar *use-implied-port-p* nil)

;;; Queries

(defun ping-node (client-socket-stream)
  "Sends the node connected to via the socket that CLIENT-SOCKET-STREAM
is linked to a ping query."
  (with-listening-usocket-stream socket
    (let ((query-dict (make-hash-table))
          (query-arguments (make-hash-table)))
      (setf (gethash "id" query-arguments) +my-id+

            (gethash "t" query-dict) (generate-transaction-id)
            (gethash "y" query-dict) "q"
            (gethash "q" query-dict) "ping"
            (gethash "a" query-dict) query-arguments)
      (bencode:encode query-dict client-socket-stream)
      (force-output client-socket-stream))
    (bencode:decode connection)))

(defun find-node (client-socket-stream node-id)
  "Sends the node connected to via the socket that CLIENT-SOCKET-STREAM
is linked to a find_node query for NODE-ID."
  (with-listening-usocket-stream socket
    (let ((query-dict (make-hash-table))
          (query-arguments (make-hash-table)))
      (setf (gethash "id" query-arguments) +my-id+
            (gethash "target" query-arguments) node-id

            (gethash "t" query-dict) (generate-transaction-id)
            (gethash "y" query-dict) "q"
            (gethash "q" query-dict) "find_node"
            (gethash "a" query-dict) query-arguments)
      (bencode:encode query-dict client-socket-stream)
      (force-output client-socket-stream))
    (bencode:decode connection)))

(defun get-peers (client-socket-stream info-hash)
  "Sends the node connected to via the socket that CLIENT-SOCKET-STREAM
is linked to a get_peers query using INFO-HASH."
  (with-listening-usocket-stream socket
    (let ((query-dict (make-hash-table))
          (query-arguments (make-hash-table)))
      (setf (gethash "id" query-arguments) +my-id+
            (gethash "info_hash" query-arguments) (ensure-hash info-hash)

            (gethash "t" query-dict) (generate-transaction-id)
            (gethash "y" query-dict) "q"
            (gethash "q" query-dict) "get_peers"
            (gethash "a" query-dict) query-arguments)
      (bencode:encode query-dict client-socket-stream)
      (force-output client-socket-stream))
    (bencode:decode connection)))

(defun announce-peer (client-socket-stream info-hash)
  "Sends the node connected to via the socket that CLIENT-SOCKET-STREAM
is linked to an announce_peer query using INFO-HASH."
  (with-listening-usocket-stream socket
    (let* ((query-dict (make-hash-table))
           (query-arguments (make-hash-table))
           (surely-hash (ensure-hash info-hash))
           (token (recall-token surely-hash)))
      (setf (gethash "id" query-arguments) +my-id+
            (gethash "implied_port" query-arguments) (if *use-implied-port-p* 1 0)
            (gethash "info_hash" query-arguments) surely-hash
            (gethash "port" query-arguments) *default-port*
            (gethash "token" query-arguments) token

            (gethash "t" query-dict) (generate-transaction-id)
            (gethash "y" query-dict) "q"
            (gethash "q" query-dict) "announce_peer"
            (gethash "a" query-dict) query-arguments)
      (bencode:encode query-dict client-socket-stream)
      (force-output client-socket-stream))
    (bencode:decode connection)))
;;; TODO: dht_error correctly
(defun dht-error (client-socket-stream type)
  "Sends the node connected to via the socket that CLIENT-SOCKET-STREAM
is linked to a dht_error message of type TYPE using TRANSACTION-ID."
  (let ((query-dict (make-hash-table)))
    (setf (gethash "t" query-dict) transaction-id
          (gethash "y" query-dict) "e"
          (gethash "e" query-dict) (case type
                                     (:generic (list 201 "Generic Error"))
                                     (:server (list 202 "Server Error"))
                                     (:protocol (list 203 "Protocol Error"))
                                     (:method (list 204 "Method Unknown"))))
    (bencode:encode query-dict client-socket-stream)
    (force-output client-socket-stream)))

(defun send-message (type node &key info-hash error-type)
  (multiple-value-bind (ip port)
      (parse-node-ip (node-ip node))
    (usocket:with-client-socket
        (target-socket target-stream ip port
                       :protocol :datagram
                       :element-type '(unsigned-byte 8)
                       :timeout 5)
      (handler-case (case type
                      (:ping (ping-node target-stream))
                      (:store)
                      (:find_node (find-node target-stream (node-id node)))
                      (:find_value)
                      (:get_peers (get-peers target-stream info-hash))
                      (:announce_peer (announce-peer target-stream info-hash)))
        (simple-error () (invoke-restart :continue))))))

;;; Responses to queries

(defun respond-to-ping (client-socket-stream dict)
  "Responds to a ping query from the node connected to via the socket
linked to by CLIENT-SOCKET-STREAM using DICT."
  (let ((response-dict (make-hash-table))
        (response-arguments (make-hash-table)))
    (setf (gethash "id" response-arguments) +my-id+

          (gethash "t" response-dict) (gethash "t" dict)
          (gethash "y" response-dict) "r"
          (gethash "r" response-dict) response-arguments)
    (bencode:encode response-dict client-socket-stream)
    (force-output client-socket-stream)))

(defun respond-to-find-node (client-socket-stream dict)
  "Responds to a find_node query from the node connected to via the socket
linked to by CLIENT-SOCKET-STREAM using DICT."
  (let ((response-dict (make-hash-table))
        (response-arguments (make-hash-table)))
    (setf (gethash "id" response-arguments) +my-id+
          (gethash "nodes" response-arguments) :TODO
          ;; TODO: response body
          (gethash "t" response-dict) (gethash "t" dict)
          (gethash "y" response-dict) "r"
          (gethash "r" response-dict) response-arguments)
    (bencode:encode response-dict client-socket-stream)
    (force-output client-socket-stream)))

(defun respond-to-get-peers (client-socket-stream dict node)
  "Responds to a get_peers query from the node NODE connected to via the socket
linked to by CLIENT-SOCKET-STREAM using DICT."
  (let* ((arguments-dict (gethash "a" dict))
         (hash (gethash "info_hash" arguments-dict))
         (peers (have-peers hash))
         (response-dict (make-hash-table))
         (response-arguments (make-hash-table)))
    (setf (gethash "id" response-arguments) +my-id+
          (gethash "token" response-arguments) (invent-token hash
                                                             (node-ip node))

          (gethash "t" response-dict) (gethash "t" dict)
          (gethash "y" response-dict) "r"
          (gethash "r" response-dict) response-arguments)
    (if peers
        (setf (gethash "values" response-arguments)
              (mapcar #'compact-node-info peers))
        (setf (gethash "nodes" response-arguments)
              (find-closest-nodes (gethash "id" arguments-dict))))
    (bencode:encode response-dict client-socket-stream)
    (force-output client-socket-stream)))

(defun respond-to-announce-peer (client-socket-stream dict client-socket)
  "Responds to an announce_peer query from the node connected to via the socket
linked to by CLIENT-SOCKET-STREAM using DICT."
  (let* ((response-dict (make-hash-table))
         (response-arguments (make-hash-table))
         (argument-dict (gethash "a" dict))
         (id (gethash "id" argument-dict))
         (implied-port-p (gethash "implied_port" argument-dict))
         (port (if (and implied-port-p (= implied-port-p 1))
                   (usocket:get-peer-port client-socket)
                   (gethash "port" argument-dict)))
         (token (gethash "token" argument-dict))
         (node (create-node :id id
                            :ip (usocket:get-peer-address client-socket)
                            :port port
                            :distance
                            (calculate-distance (convert-id-to-int id)
                                                (convert-id-to-int +my-id+))
                            :last-activity (get-universal-time)
                            :health :good
                            :hashes (list (gethash "info_hash"
                                                   argument-dict)))))
    (consider-token node token)
    (add-to-bucket node)
    (setf (gethash "id" response-arguments) +my-id+

          (gethash "t" response-dict) (gethash "t" dict)
          (gethash "y" response-dict) "r"
          (gethash "r" response-dict) response-arguments)
    (bencode:encode response-dict client-socket-stream)
    (force-output client-socket-stream)))

(defun send-response (type node dict)
  (multiple-value-bind (ip port)
      (parse-node-ip (node-ip node))
    (usocket:with-client-socket
        (target-socket target-stream ip port
                       :protocol :datagram
                       :element-type '(unsigned-byte 8)
                       :timeout 5)
      (handler-case (case type
                      (:ping
                       (respond-to-ping target-stream dict))
                      (:find_node
                       (respond-to-find-node target-stream dict))
                      (:get_peers
                       (respond-to-get-peers target-stream dict node))
                      (:announce_peer
                       (respond-to-announce-peer target-stream
                                                 dict
                                                 target-socket)))
        (simple-error () (invoke-restart :continue))))))

;;;; Everything below this point is being rewritten

(defun format-nodes (list-of-nodes)
  "Formats a list of nodes appropriately for bencoding."
  (with-output-to-string (x)
    (princ "l" x)
    (mapc (lambda (a)
            (princ "26:" x)
            (princ (node-id a) x)
            (princ (node-ip a) x))
          list-of-nodes)
    (princ "e" x)))
