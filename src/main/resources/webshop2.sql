CREATE TABLE IF NOT EXISTS accounts (
    client_id INTEGER PRIMARY KEY,
    amount DECIMAL DEFAULT 0,
    deactivated BOOLEAN DEFAULT FALSE,
    FOREIGN KEY (client_id) REFERENCES clients(id)
);

INSERT INTO accounts (client_id, amount) VALUES
    (1, 70000),
    (2, 3000);

CREATE TABLE IF NOT EXISTS transfers (
    transfer_id SERIAL PRIMARY KEY,
    from_client_id INTEGER,
    to_client_id INTEGER,
    date DATE DEFAULT now(),
    amount DECIMAL,
    FOREIGN KEY (from_client_id) REFERENCES clients(id),
    FOREIGN KEY (to_client_id) REFERENCES clients(id)
);

INSERT INTO transfers (from_client_id, to_client_id, amount) VALUES
    (1, 2, 60000),
    (2, 1, 5900000),
    (2, 1, 69000),
    (1, 2, 300);

CREATE OR REPLACE FUNCTION steuer(date date)
    RETURNS DECIMAL
AS $$
BEGIN
    IF date_part('year', date) < 2020 THEN
        RETURN 0.02;
    ELSE
        RETURN 0.01;
    END IF;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION bilanz(client_id INTEGER)
    RETURNS INTEGER
AS $$
DECLARE
    einzahlungen DECIMAL;
    auszahlungen DECIMAL;
BEGIN
    SELECT COALESCE(SUM(amount),0) INTO einzahlungen FROM (SELECT SUM(amount) * (1 - steuer(date)) AS amount FROM transfers WHERE to_client_id = client_id GROUP BY steuer(date)) as tSs;
    SELECT COALESCE(SUM(amount),0) INTO auszahlungen FROM (SELECT SUM(amount) * (1 - steuer(date)) AS amount FROM transfers WHERE from_client_id = client_id GROUP BY steuer(date)) as ta;
    RETURN einzahlungen - auszahlungen;
END;
$$ LANGUAGE plpgsql;

CREATE OR  REPLACE  PROCEDURE transfer_direct(sender INTEGER, recipient INTEGER, transferAmount DECIMAL)
AS $$
BEGIN
    UPDATE accounts SET amount = amount - transferAmount WHERE client_id = sender;
    UPDATE accounts SET amount = amount + transferAmount WHERE client_id = recipient;

    IF (SELECT amount FROM accounts WHERE client_id = sender) < 0 THEN
        ROLLBACK;
        RAISE NOTICE 'Der Sender hat nicht genügend Guthaben auf seinem Konto';
        RAISE EXCEPTION 'Der Sender hat nicht genügend Guthaben auf seinem Konto';
    END IF;

    COMMIT;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION update_accounts()
    RETURNS trigger
AS $$
BEGIN
    IF (SELECT amount - new.amount FROM accounts WHERE client_id = new.from_client_id) < 0 THEN
        RETURN null;
    END IF;

    UPDATE accounts SET amount = amount - new.amount WHERE client_id = new.from_client_id;
    UPDATE accounts SET amount = amount + new.amount WHERE client_id = new.to_client_id;

    RETURN new;
END
$$ LANGUAGE plpgsql;

CREATE TRIGGER new_transfer BEFORE INSERT ON transfers FOR EACH ROW EXECUTE PROCEDURE update_accounts();
