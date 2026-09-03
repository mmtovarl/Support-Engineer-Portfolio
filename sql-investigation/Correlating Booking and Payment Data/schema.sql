CREATE TABLE bookings (
  booking_id INTEGER PRIMARY KEY,
  guest_id INTEGER,
  property_id INTEGER,
  check_in DATE,
  check_out DATE,
  amount DECIMAL(10,2),
  created_at DATETIME
);

CREATE TABLE payments (
  payment_id INTEGER PRIMARY KEY,
  booking_id INTEGER,
  amount DECIMAL(10,2),
  status TEXT,
  created_at DATETIME
);

CREATE TABLE sync_log (
  sync_id INTEGER PRIMARY KEY,
  booking_id INTEGER,
  sync_status TEXT,
  error_message TEXT,
  synced_at DATETIME
);
