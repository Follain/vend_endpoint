module Vend
  class CustomerBuilder
    class << self

      def build_update_customer(client, payload)
        hash = build_new_customer(client, payload)
        customer = client.retrieve_customers(nil, payload['email'], nil)

        hash[:id] = customer['customers'][0]['id'] if !customer['customers'][0].nil?
        hash
      end

      def build_new_customer(client, payload)
        if !payload['shipping_address'].nil?
        hash = {
          'email'               => payload['email'],
          'first_name'          => payload['shipping_address']['firstname'],
          'last_name'           => payload['shipping_address']['lastname'],
          'physical_address1'   => payload['shipping_address']['address1'],
          'physical_address2'   => payload['shipping_address']['address2'],
          'physical_postcode'   => payload['shipping_address']['zipcode'],
          'physical_city'       => payload['shipping_address']['city'],
          'physical_state'      => payload['shipping_address']['state'],
          'physical_country_id' => payload['shipping_address']['country']
        }
      else
        hash = {
          'email'               => payload['email'],
          'first_name'          => nil,
          'last_name'           => nil,
          'physical_address1'   => nil,
          'physical_address2'   => nil,
          'physical_postcode'   => nil,
          'physical_city'       => nil,
          'physical_state'      => nil,
          'physical_country_id' => nil
        }
      end
        hash['customer_code'] = payload['email']
        hash
      end

      def parse_customer(vend_customer)
        {
          :id                => vend_customer['customer_code'] || vend_customer['id'],
          'firstname'        => first_name(vend_customer['name']),
          'lastname'         => last_name(vend_customer['name']),
          'email'            => vend_customer['email'],
          'shipping_address' => parse_shipping_address(vend_customer),
          'billing_address'  => parse_billing_address(vend_customer)
        }
      end

      def parse_shipping_address(vend_customer)
        {
          'address1' => vend_customer['physical_address1'],
          'address2' => vend_customer['physical_address2'],
          'zipcode'  => vend_customer['physical_postcode'],
          'city'     => vend_customer['physical_city'],
          'state'    => vend_customer['physical_state'],
          'country'  => vend_customer['physical_country_id'],
          'phone'    => vend_customer['phone']
        }
      end

      def parse_billing_address(vend_customer)
        {
          'address1' => vend_customer['postal_address1'],
          'address2' => vend_customer['postal_address2'],
          'zipcode'  => vend_customer['postal_postcode'],
          'city'     => vend_customer['postal_city'],
          'state'    => vend_customer['postal_state'],
          'country'  => vend_customer['postal_country_id'],
          'phone'    => vend_customer['phone']
        }
      end

      def parse_customer_for_order(vend_customer)
        hash = {
          'email'            => vend_customer['email'],
          'shipping_address' => parse_shipping_address(vend_customer),
          'billing_address'  => parse_billing_address(vend_customer)
        }

        hash['shipping_address']['firstname'] = first_name(vend_customer['name'])
        hash['shipping_address']['lastname']  = last_name(vend_customer['name'])
        hash['billing_address']['firstname']  = first_name(vend_customer['name'])
        hash['billing_address']['lastname']   = last_name(vend_customer['name'])

        hash
      end

      def first_name(name)
        return '' if name.nil?
        name.split(' ')[0]
      end

      def last_name(name)
        return '' if name.nil?
        name.split(' ').drop(1).join(' ')
      end
    end
  end
end