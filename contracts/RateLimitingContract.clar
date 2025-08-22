;; AMM with Stable Curves Contract
;; Automated Market Maker implementation with stable curve pricing and transaction rate limiting

;; Define fungible tokens for the AMM pair
(define-fungible-token token-a)
(define-fungible-token token-b)
(define-fungible-token lp-token)

;; Constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-invalid-amount (err u101))
(define-constant err-insufficient-balance (err u102))
(define-constant err-rate-limit-exceeded (err u103))
(define-constant err-slippage-too-high (err u104))

;; AMM Pool state
(define-data-var reserve-a uint u0)
(define-data-var reserve-b uint u0)
(define-data-var total-lp-supply uint u0)

;; Rate limiting configuration
(define-data-var rate-limit-window uint u144) ;; ~24 hours in blocks
(define-data-var max-transactions-per-window uint u10)

;; Rate limiting tracking
(define-map user-transactions 
  principal 
  {
    last-reset-block: uint,
    transaction-count: uint
  })

;; Stable curve parameters
(define-data-var amplification-coefficient uint u100)

;; Get current block height helper (not needed, removed)

;; Check and update rate limit for user
(define-private (check-rate-limit (user principal))
  (let (
    (user-data (match (map-get? user-transactions user)
                      some-data some-data
                      {last-reset-block: u0, transaction-count: u0}))
    (window-size (var-get rate-limit-window))
    (max-tx (var-get max-transactions-per-window))
    (current-height burn-block-height)
  )
    (let ((last-reset (get last-reset-block user-data)))
      (if (or (is-eq last-reset u0) 
              (>= current-height (+ last-reset window-size)))
          ;; Reset window - user can proceed
          (begin
            (map-set user-transactions user {
              last-reset-block: current-height,
              transaction-count: u1
            })
            (ok true))
          ;; Check if within limits
          (if (< (get transaction-count user-data) max-tx)
              ;; Increment counter
              (begin
                (map-set user-transactions user {
                  last-reset-block: last-reset,
                  transaction-count: (+ (get transaction-count user-data) u1)
                })
                (ok true))
              ;; Rate limit exceeded
              err-rate-limit-exceeded)))))

;; Function 1: Swap tokens using stable curve formula
(define-public (stable-swap 
                (amount-in uint) 
                (token-in-is-a bool) 
                (min-amount-out uint))
  (begin
    ;; Check rate limit first
    (try! (check-rate-limit tx-sender))
    
    ;; Validate input
    (asserts! (> amount-in u0) err-invalid-amount)
    
    (let (
      (reserve-in (if token-in-is-a (var-get reserve-a) (var-get reserve-b)))
      (reserve-out (if token-in-is-a (var-get reserve-b) (var-get reserve-a)))
      (A (var-get amplification-coefficient))
      
      ;; Simplified stable curve calculation
      ;; Using constant product with amplification factor for demonstration
      (new-reserve-in (+ reserve-in amount-in))
      (product (* A (* reserve-in reserve-out)))
      (amount-out (if (> new-reserve-in u0) 
                     (- reserve-out (/ product new-reserve-in))
                     u0))
    )
      
      ;; Check slippage protection
      (asserts! (>= amount-out min-amount-out) err-slippage-too-high)
      (asserts! (> amount-out u0) err-invalid-amount)
      
      ;; Check user has sufficient balance
      (if token-in-is-a
          (asserts! (>= (ft-get-balance token-a tx-sender) amount-in) err-insufficient-balance)
          (asserts! (>= (ft-get-balance token-b tx-sender) amount-in) err-insufficient-balance))
      
      ;; Execute the swap
      (if token-in-is-a
          (begin
            (try! (ft-transfer? token-a amount-in tx-sender (as-contract tx-sender)))
            (try! (as-contract (ft-transfer? token-b amount-out tx-sender tx-sender)))
            (var-set reserve-a (+ reserve-in amount-in))
            (var-set reserve-b (- reserve-out amount-out)))
          (begin
            (try! (ft-transfer? token-b amount-in tx-sender (as-contract tx-sender)))
            (try! (as-contract (ft-transfer? token-a amount-out tx-sender tx-sender)))
            (var-set reserve-b (+ reserve-in amount-in))
            (var-set reserve-a (- reserve-out amount-out))))
      
      (ok {
        amount-out: amount-out, 
        new-reserve-a: (var-get reserve-a), 
        new-reserve-b: (var-get reserve-b)
      }))))

;; Function 2: Add liquidity to the stable curve pool
(define-public (add-liquidity 
                (amount-a uint) 
                (amount-b uint) 
                (min-lp-tokens uint))
  (begin
    ;; Check rate limit
    (try! (check-rate-limit tx-sender))
    
    ;; Validate inputs
    (asserts! (and (> amount-a u0) (> amount-b u0)) err-invalid-amount)
    
    ;; Check user balances
    (asserts! (>= (ft-get-balance token-a tx-sender) amount-a) err-insufficient-balance)
    (asserts! (>= (ft-get-balance token-b tx-sender) amount-b) err-insufficient-balance)
    
    (let (
      (current-reserve-a (var-get reserve-a))
      (current-reserve-b (var-get reserve-b))
      (current-lp-supply (var-get total-lp-supply))
      
      ;; Calculate LP tokens to mint
      (lp-tokens-to-mint 
        (if (is-eq current-lp-supply u0)
            ;; First liquidity provision - simple formula
            (+ (* amount-a u100) (* amount-b u100))
            ;; Subsequent liquidity - proportional to reserves
            (let (
              (ratio-a (if (> current-reserve-a u0) 
                          (/ (* amount-a current-lp-supply) current-reserve-a) 
                          u0))
              (ratio-b (if (> current-reserve-b u0) 
                          (/ (* amount-b current-lp-supply) current-reserve-b) 
                          u0))
            )
              (if (and (> ratio-a u0) (> ratio-b u0))
                  (if (< ratio-a ratio-b) ratio-a ratio-b)
                  (+ ratio-a ratio-b)))))
    )
      
      ;; Ensure minimum LP tokens
      (asserts! (> lp-tokens-to-mint u0) err-invalid-amount)
      (asserts! (>= lp-tokens-to-mint min-lp-tokens) err-slippage-too-high)
      
      ;; Transfer tokens to contract
      (try! (ft-transfer? token-a amount-a tx-sender (as-contract tx-sender)))
      (try! (ft-transfer? token-b amount-b tx-sender (as-contract tx-sender)))
      
      ;; Mint LP tokens to user
      (try! (ft-mint? lp-token lp-tokens-to-mint tx-sender))
      
      ;; Update reserves and total supply
      (var-set reserve-a (+ current-reserve-a amount-a))
      (var-set reserve-b (+ current-reserve-b amount-b))
      (var-set total-lp-supply (+ current-lp-supply lp-tokens-to-mint))
      
      (ok {
        lp-tokens-minted: lp-tokens-to-mint,
        new-reserve-a: (var-get reserve-a),
        new-reserve-b: (var-get reserve-b),
        new-lp-supply: (var-get total-lp-supply)
      }))))

;; Read-only functions
(define-read-only (get-pool-info)
  (ok {
    reserve-a: (var-get reserve-a),
    reserve-b: (var-get reserve-b),
    lp-supply: (var-get total-lp-supply),
    amplification-coefficient: (var-get amplification-coefficient)
  }))

(define-read-only (get-user-rate-limit-status (user principal))
  (let (
    (user-data (match (map-get? user-transactions user)
                      some-data some-data
                      {last-reset-block: u0, transaction-count: u0}))
    (window-size (var-get rate-limit-window))
  )
    (ok {
      transactions-used: (get transaction-count user-data),
      max-transactions: (var-get max-transactions-per-window),
      window-expires-at: (+ (get last-reset-block user-data) window-size),
      current-block: burn-block-height
    })))

(define-read-only (get-rate-limit-config)
  (ok {
    window-blocks: (var-get rate-limit-window),
    max-transactions: (var-get max-transactions-per-window)
  }))