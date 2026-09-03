SELECT * 
FROM bookings
LEFT JOIN payments ON bookings.booking_id=payments.booking_id
WHERE payment_id IS NULL;


SELECT * 
FROM bookings
LEFT JOIN payments ON bookings.booking_id=payments.booking_id
WHERE bookings.amount != payments.amount 
   OR payments.payment_id IS NULL;


SELECT *
FROM bookings
LEFT JOIN payments ON bookings.booking_id = payments.booking_id
LEFT JOIN sync_log ON bookings.booking_id = sync_log.booking_id
WHERE sync_log.sync_status = 'failed' 
  AND (payments.payment_id IS NULL 
  OR payments.status = 'failed');
