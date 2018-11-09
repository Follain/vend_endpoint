require 'digest'
require 'active_support/all'

module Vend
  class ProductBuilder
    class << self
      def build(client, payload)
        sku = payload['sku'].presence
        hash = {
            'source_id'         => payload['variant_id'],
            'handle'            => payload['handle'],
            'tags'              => payload['tags'],
            'name'              => payload['name'],
            'description'       => payload['description'],
            'track_inventory'   => payload['track_inventory'],
            'sku'               => sku,
            'active'            => payload['active'],
            'retail_price'      => payload['price'],
            'supply_price'      => payload['cost_price'],
            'brand_name'        => payload['brand'],
            'department'        => payload['department'],
            'category'          => payload['category']
            }

        hash[:id] = payload['id'] if payload.has_key?('id')
        hash[:inventory] = payload['inventory'] if payload.has_key?('inventory')

            %w(one two three).each_with_index do |opt, index|
                if payload['options'].present? && payload["options"][index].present?
                  hash.merge!(
                    "variant_option_#{opt}_name" => payload["options"][index]['option_name'],
                    "variant_option_#{opt}_value" => payload["options"][index]['option_value']
                  )
                  else
                    hash.merge!(
                      "variant_option_#{opt}_name" => nil,
                      "variant_option_#{opt}_value" => nil
                    )
                end
              end

        hash
      end

      def parse_product(product)
        hash = {
                :id                 => product['id'],
                :channel            => 'Vend',
                'name'              => product['name'].split("/")[0],
                'source_id'         => product['source_id'],
                'sku'               => product['sku'],
                'handle'            => product['handle'],
                'description'       => product['description'],
                'price'             => product['price'],
                'permalink'         => product['sku'],
                'track_inventory'   => product['track_inventory'],
                'meta_keywords'     => product['tags'],
                'updated_at'        => product['updated_at'],
                'images'=> [
                  {
                    'url'=> product['image']
                  }
                ]
              }
        hash
      end

      private

    end
  end
end