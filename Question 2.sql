-- Q2(a) Tables & Seed Data
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number VARCHAR(30) NOT NULL UNIQUE,
    full_name      VARCHAR(120) NOT NULL,
    fee_due        NUMERIC(12, 2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12, 2) NOT NULL CHECK (amount > 0),
    paid_on    DATE NOT NULL
);

CREATE TABLE payment_audit (
    audit_id   SERIAL PRIMARY KEY,
    payment_id INTEGER NOT NULL REFERENCES payments(payment_id),
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12, 2) NOT NULL,
    logged_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count   INTEGER NOT NULL DEFAULT 0 CHECK (payment_count >= 0),
    total_amount    NUMERIC(12, 2) NOT NULL DEFAULT 0.00 CHECK (total_amount >= 0)
);

-- Q2(b) Function: fn_fee_balance
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INT)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee_due NUMERIC(12, 2);
    v_paid    NUMERIC(12, 2);
BEGIN
    SELECT fee_due INTO v_fee_due
    FROM students
    WHERE student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0.00) INTO v_paid
    FROM payments
    WHERE student_id = p_student_id;

    RETURN v_fee_due - v_paid;
END;
$$;

-- Q2(c) Procedure: pr_receive_payment (does NOT insert into payment_audit)
CREATE OR REPLACE PROCEDURE pr_receive_payment(
    p_student_id INT,
    p_amount     NUMERIC(12, 2),
    p_paid_on    DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance NUMERIC(12, 2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be positive, got %', p_amount;
    END IF;

    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id: %', p_student_id;
    END IF;

    v_balance := fn_fee_balance(p_student_id);

    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment %.2f exceeds outstanding balance %.2f', p_amount, v_balance;
    END IF;

    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);
END;
$$;

-- Q2(d) Trigger: AFTER INSERT on payments -> payment_audit
CREATE OR REPLACE FUNCTION fn_trg_payments_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, NOW());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payments_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION fn_trg_payments_audit();

-- Seed 3 students (student 3 has 0 payments) and 6 payments
INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('STU-2026-001', 'Mutale Banda', 10000.00),
    ('STU-2026-002', 'Chanda Phiri', 8000.00),
    ('STU-2026-003', 'Thandiwe Mwale', 12000.00);

CALL pr_receive_payment(1, 3000.00, CURRENT_DATE - 2);
CALL pr_receive_payment(1, 2000.00, CURRENT_DATE - 1);
CALL pr_receive_payment(1, 5000.00, CURRENT_DATE - 1); -- Settled in full
CALL pr_receive_payment(2, 2500.00, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1500.00, CURRENT_DATE);
CALL pr_receive_payment(2, 1000.00, CURRENT_DATE);

-- Q2(e) View: excludes fully settled students
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT
    s.student_number,
    s.full_name,
    fn_fee_balance(s.student_id) AS outstanding_balance
FROM students s
WHERE fn_fee_balance(s.student_id) > 0;

-- Q2(f) Composite Index & EXPLAIN
-- Equality on student_id narrows rows first, then range scan on paid_on
CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);

EXPLAIN (ANALYZE, BUFFERS)
SELECT *
FROM payments
WHERE student_id = 2
  AND paid_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
-- Expected plan node: Index Scan using idx_payments_student_paid_on on payments

-- Q2(g) Procedure & Scheduled Job (01:00 daily for previous day)
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_count  INTEGER;
    v_amount NUMERIC(12, 2);
BEGIN
    SELECT COUNT(*), COALESCE(SUM(amount), 0.00)
    INTO v_count, v_amount
    FROM payments
    WHERE paid_on = p_day;

    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    VALUES (p_day, v_count, v_amount)
    ON CONFLICT (collection_date) DO UPDATE
    SET payment_count = EXCLUDED.payment_count,
        total_amount  = EXCLUDED.total_amount;
END;
$$;

SELECT cron.schedule(
    'refresh_daily_collections',
    '0 1 * * *',
    $$CALL pr_refresh_collections((CURRENT_TIMESTAMP AT TIME ZONE 'Africa/Lusaka')::date - 1);$$
);