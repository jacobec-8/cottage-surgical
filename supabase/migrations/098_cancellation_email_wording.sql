-- 098: A cancellation email says "denied" only when the store declined the
-- request; otherwise (customer called, changed their mind at the counter) it says
-- the order was cancelled. Found in the busy-day scenario run.

CREATE OR REPLACE FUNCTION public.queue_order_status_email()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_event TEXT; v_subject TEXT; v_heading TEXT; v_message TEXT;
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.status IS NOT DISTINCT FROM NEW.status THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' AND NEW.status = 'requested' THEN
    v_event := 'request_received';
    v_subject := 'Rental request #' || NEW.order_no || ' received';
    v_heading := 'We received your rental request';
    v_message := CASE WHEN NEW.payment_preference = 'on_delivery'
      THEN 'Our team is reviewing your equipment and delivery details. Payment will be collected by the delivery person when your equipment arrives.'
      WHEN NEW.fulfillment_method = 'pickup'
      THEN 'Our team is reviewing your equipment and pickup details. Please expect a call from the pharmacy to confirm your pickup. Payment will be collected in store after approval.'
      ELSE 'Our team is reviewing your equipment and delivery details.' END;
  ELSIF TG_OP = 'UPDATE' AND OLD.status = 'pending_payment'
        AND NEW.status = 'requested' AND NEW.payment_status = 'paid' THEN
    v_event := 'payment_received';
    v_subject := 'Payment received for rental request #' || NEW.order_no;
    v_heading := 'Payment received and request submitted';
    v_message := CASE WHEN NEW.fulfillment_method = 'pickup'
      THEN 'We received your first month rental payment. Please expect a call from the pharmacy to confirm your pickup.'
      ELSE 'We received your first month rental payment. Our team is reviewing your equipment and delivery details.' END;
  ELSIF NEW.status = 'open' THEN
    v_event := 'request_accepted';
    v_subject := 'Rental request #' || NEW.order_no || ' approved';
    v_heading := 'Your rental request was approved';
    v_message := CASE WHEN NEW.fulfillment_method = 'pickup'
      THEN 'Your equipment is reserved at the pharmacy. Our team will confirm your pickup date and time.'
      ELSE 'Your equipment is reserved. A separate scheduling email will include the delivery date, time window, and location.' END;
  ELSIF NEW.status = 'active' THEN
    v_event := 'rental_active';
    v_subject := CASE WHEN NEW.fulfillment_method = 'pickup'
      THEN 'Pickup completed for order #' || NEW.order_no
      ELSE 'Delivery completed for order #' || NEW.order_no END;
    v_heading := CASE WHEN NEW.fulfillment_method = 'pickup'
      THEN 'Your equipment was picked up'
      ELSE 'Your rental was delivered' END;
    v_message := CASE WHEN NEW.fulfillment_method = 'pickup'
      THEN 'Your in-store pickup is complete. Your rental period is open.'
      ELSE 'Delivery is complete. Your rental period is open.' END;
  ELSIF NEW.status = 'closed' THEN
    v_event := 'order_completed';
    v_subject := 'Rental #' || NEW.order_no || ' closed';
    v_heading := CASE WHEN NEW.order_type = 'rental' THEN 'Your rental is closed' ELSE 'Your order is complete' END;
    v_message := CASE WHEN NEW.order_type = 'rental'
      THEN 'Pickup is complete. The rental period is closed. Thank you for choosing '
        || COALESCE((SELECT b.name FROM public.order_brand(NEW.id) b), 'us') || '.'
      ELSE 'Delivery is complete. Thank you for choosing '
        || COALESCE((SELECT b.name FROM public.order_brand(NEW.id) b), 'us') || '.' END;
  ELSIF NEW.status = 'cancelled' THEN
    IF TG_OP = 'UPDATE' AND OLD.status = 'pending_payment'
       AND NEW.payment_status <> 'paid' AND NEW.payment_status <> 'refunded' THEN
      RETURN NEW;
    END IF;
    v_event := CASE WHEN NEW.payment_status = 'refunded' THEN 'order_cancelled_refunded' ELSE 'order_cancelled' END;
    -- "Denied" only when the store declines a request; a customer who calls to
    -- cancel or changes their mind at the counter gets a plain cancellation (098).
    IF OLD.status = 'requested' AND NEW.closed_reason = 'Declined from the Requests inbox' THEN
      v_subject := 'Rental request #' || NEW.order_no || ' decision';
      v_heading := CASE WHEN NEW.payment_status = 'refunded'
        THEN 'Your rental request was denied and refunded'
        ELSE 'Your rental request was denied' END;
      v_message := CASE WHEN NEW.payment_status = 'refunded'
        THEN 'We are unable to fulfill this request. Delivery and pickup are canceled. A full refund was initiated to your original Stripe payment method. Your bank may take several business days to post it.'
        ELSE 'We are unable to fulfill this request. Delivery and pickup are canceled. The balance due is $0.00. Please call us for help with another option.' END;
    ELSE
      v_subject := 'Order #' || NEW.order_no || ' cancelled';
      v_heading := CASE WHEN NEW.payment_status = 'refunded'
        THEN 'Your order was cancelled and refunded'
        ELSE 'Your order was cancelled' END;
      v_message := CASE WHEN NEW.payment_status = 'refunded'
        THEN 'Your order has been cancelled and a full refund was initiated to your original payment method. Your bank may take several business days to post it.'
        ELSE 'Your order has been cancelled and nothing is due. If this was a mistake or you would like to order again, please call us.' END;
    END IF;
  ELSE
    RETURN NEW;
  END IF;

  PERFORM public.queue_customer_status_email(
    NEW.id, v_event, v_subject, v_heading, v_message);
  RETURN NEW;
EXCEPTION WHEN others THEN
  RETURN NEW;
END;
$function$;
