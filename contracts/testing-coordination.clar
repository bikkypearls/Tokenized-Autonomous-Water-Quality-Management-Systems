;; Testing Coordination Contract
;; Schedules regular water quality assessments

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u300))
(define-constant ERR_INVALID_TEST (err u301))
(define-constant ERR_INVALID_DATE (err u302))
(define-constant ERR_NOT_FOUND (err u303))
(define-constant ERR_ALREADY_COMPLETED (err u304))
(define-constant ERR_FACILITY_BUSY (err u305))

;; Data Variables
(define-data-var next-test-id uint u1)
(define-data-var next-facility-id uint u1)
(define-data-var testing-frequency uint u604800) ;; 7 days in seconds
(define-data-var total-tests-completed uint u0)

;; Data Maps
(define-map test-schedules
  uint
  {
    location: (string-ascii 50),
    test-type: (string-ascii 30),
    scheduled-date: uint,
    facility-id: uint,
    priority: uint,
    status: (string-ascii 20),
    requester: principal
  }
)

(define-map test-results
  uint
  {
    test-id: uint,
    completion-date: uint,
    results: (string-ascii 200),
    pass-status: bool,
    technician: principal,
    notes: (string-ascii 150)
  }
)

(define-map testing-facilities
  uint
  {
    name: (string-ascii 50),
    location: (string-ascii 50),
    capacity: uint,
    specializations: (string-ascii 100),
    active: bool,
    current-load: uint
  }
)

(define-map facility-schedule
  { facility-id: uint, date: uint }
  {
    scheduled-tests: uint,
    available-slots: uint
  }
)

(define-map location-testing-history
  (string-ascii 50)
  {
    total-tests: uint,
    passed-tests: uint,
    failed-tests: uint,
    last-test-date: uint,
    next-scheduled: uint
  }
)

;; Public Functions

;; Register testing facility
(define-public (register-facility
  (name (string-ascii 50))
  (location (string-ascii 50))
  (capacity uint)
  (specializations (string-ascii 100)))
  (let
    (
      (facility-id (var-get next-facility-id))
    )
    (asserts! (> (len name) u0) ERR_INVALID_TEST)
    (asserts! (> (len location) u0) ERR_INVALID_TEST)
    (asserts! (> capacity u0) ERR_INVALID_TEST)

    (map-set testing-facilities facility-id
      {
        name: name,
        location: location,
        capacity: capacity,
        specializations: specializations,
        active: true,
        current-load: u0
      }
    )

    (var-set next-facility-id (+ facility-id u1))
    (ok facility-id)
  )
)

;; Schedule water quality test
(define-public (schedule-test
  (location (string-ascii 50))
  (test-type (string-ascii 30))
  (scheduled-date uint)
  (facility-id uint)
  (priority uint))
  (let
    (
      (test-id (var-get next-test-id))
      (facility (unwrap! (map-get? testing-facilities facility-id) ERR_NOT_FOUND))
      (current-time block-height)
    )
    (asserts! (> (len location) u0) ERR_INVALID_TEST)
    (asserts! (> (len test-type) u0) ERR_INVALID_TEST)
    (asserts! (> scheduled-date current-time) ERR_INVALID_DATE)
    (asserts! (and (>= priority u1) (<= priority u5)) ERR_INVALID_TEST)
    (asserts! (get active facility) ERR_NOT_FOUND)

    ;; Check facility availability
    (asserts! (is-facility-available facility-id scheduled-date) ERR_FACILITY_BUSY)

    ;; Schedule the test
    (map-set test-schedules test-id
      {
        location: location,
        test-type: test-type,
        scheduled-date: scheduled-date,
        facility-id: facility-id,
        priority: priority,
        status: "scheduled",
        requester: tx-sender
      }
    )

    ;; Update facility schedule
    (update-facility-schedule facility-id scheduled-date)

    ;; Update location testing history
    (update-location-schedule location scheduled-date)

    (var-set next-test-id (+ test-id u1))
    (ok test-id)
  )
)

;; Record test results
(define-public (record-test-results
  (test-id uint)
  (results (string-ascii 200))
  (pass-status bool)
  (notes (string-ascii 150)))
  (let
    (
      (test-schedule (unwrap! (map-get? test-schedules test-id) ERR_NOT_FOUND))
      (current-time block-height)
    )
    (asserts! (is-eq (get status test-schedule) "scheduled") ERR_ALREADY_COMPLETED)

    ;; Record test results
    (map-set test-results test-id
      {
        test-id: test-id,
        completion-date: current-time,
        results: results,
        pass-status: pass-status,
        technician: tx-sender,
        notes: notes
      }
    )

    ;; Update test schedule status
    (map-set test-schedules test-id
      (merge test-schedule { status: "completed" })
    )

    ;; Update location testing history
    (update-location-test-history (get location test-schedule) pass-status current-time)

    ;; Update facility load
    (reduce-facility-load (get facility-id test-schedule))

    ;; Update total completed tests
    (var-set total-tests-completed (+ (var-get total-tests-completed) u1))

    ;; Schedule next regular test if needed
    (schedule-next-regular-test (get location test-schedule))

    (ok true)
  )
)

;; Cancel scheduled test
(define-public (cancel-test (test-id uint))
  (let
    (
      (test-schedule (unwrap! (map-get? test-schedules test-id) ERR_NOT_FOUND))
    )
    (asserts! (or (is-eq tx-sender (get requester test-schedule)) (is-eq tx-sender CONTRACT_OWNER)) ERR_UNAUTHORIZED)
    (asserts! (is-eq (get status test-schedule) "scheduled") ERR_ALREADY_COMPLETED)

    ;; Update test status
    (map-set test-schedules test-id
      (merge test-schedule { status: "cancelled" })
    )

    ;; Free up facility slot
    (reduce-facility-load (get facility-id test-schedule))

    (ok true)
  )
)

;; Set testing frequency (admin only)
(define-public (set-testing-frequency (new-frequency uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (> new-frequency u0) ERR_INVALID_TEST)
    (var-set testing-frequency new-frequency)
    (ok true)
  )
)

;; Read-only Functions

;; Get test schedule
(define-read-only (get-test-schedule (test-id uint))
  (map-get? test-schedules test-id)
)

;; Get test results
(define-read-only (get-test-results (test-id uint))
  (map-get? test-results test-id)
)

;; Get facility information
(define-read-only (get-facility-info (facility-id uint))
  (map-get? testing-facilities facility-id)
)

;; Get location testing history
(define-read-only (get-location-history (location (string-ascii 50)))
  (map-get? location-testing-history location)
)

;; Get testing frequency
(define-read-only (get-testing-frequency)
  (var-get testing-frequency)
)

;; Get total completed tests
(define-read-only (get-total-completed-tests)
  (var-get total-tests-completed)
)

;; Check if facility is available
(define-read-only (is-facility-available (facility-id uint) (date uint))
  (let
    (
      (facility (unwrap! (map-get? testing-facilities facility-id) false))
      (schedule (default-to
        { scheduled-tests: u0, available-slots: (get capacity facility) }
        (map-get? facility-schedule { facility-id: facility-id, date: date })
      ))
    )
    (> (get available-slots schedule) u0)
  )
)

;; Get facility utilization
(define-read-only (get-facility-utilization (facility-id uint))
  (match (map-get? testing-facilities facility-id)
    facility (/ (* (get current-load facility) u100) (get capacity facility))
    u0
  )
)

;; Private Functions

;; Update facility schedule
(define-private (update-facility-schedule (facility-id uint) (date uint))
  (let
    (
      (facility (unwrap-panic (map-get? testing-facilities facility-id)))
      (current-schedule (default-to
        { scheduled-tests: u0, available-slots: (get capacity facility) }
        (map-get? facility-schedule { facility-id: facility-id, date: date })
      ))
    )
    ;; Update facility schedule
    (map-set facility-schedule { facility-id: facility-id, date: date }
      {
        scheduled-tests: (+ (get scheduled-tests current-schedule) u1),
        available-slots: (- (get available-slots current-schedule) u1)
      }
    )

    ;; Update facility current load
    (map-set testing-facilities facility-id
      (merge facility { current-load: (+ (get current-load facility) u1) })
    )
  )
)

;; Reduce facility load
(define-private (reduce-facility-load (facility-id uint))
  (let
    (
      (facility (unwrap-panic (map-get? testing-facilities facility-id)))
    )
    (map-set testing-facilities facility-id
      (merge facility {
        current-load: (if (> (get current-load facility) u0)
                        (- (get current-load facility) u1)
                        u0)
      })
    )
  )
)

;; Update location testing history
(define-private (update-location-test-history (location (string-ascii 50)) (passed bool) (test-date uint))
  (let
    (
      (history (default-to
        { total-tests: u0, passed-tests: u0, failed-tests: u0, last-test-date: u0, next-scheduled: u0 }
        (map-get? location-testing-history location)
      ))
    )
    (map-set location-testing-history location
      {
        total-tests: (+ (get total-tests history) u1),
        passed-tests: (if passed (+ (get passed-tests history) u1) (get passed-tests history)),
        failed-tests: (if passed (get failed-tests history) (+ (get failed-tests history) u1)),
        last-test-date: test-date,
        next-scheduled: (get next-scheduled history)
      }
    )
  )
)

;; Update location schedule
(define-private (update-location-schedule (location (string-ascii 50)) (scheduled-date uint))
  (let
    (
      (history (default-to
        { total-tests: u0, passed-tests: u0, failed-tests: u0, last-test-date: u0, next-scheduled: u0 }
        (map-get? location-testing-history location)
      ))
    )
    (map-set location-testing-history location
      (merge history { next-scheduled: scheduled-date })
    )
  )
)

;; Schedule next regular test
(define-private (schedule-next-regular-test (location (string-ascii 50)))
  (let
    (
      (current-time block-height)
      (next-test-time (+ current-time (var-get testing-frequency)))
    )
    ;; This would typically trigger automatic scheduling
    ;; For now, just update the expected next test time
    (update-location-schedule location next-test-time)
  )
)
