require 'digest'
require 'active_support/all'

module Vend
  class ProductBuilder
    class << self
      def build(client, payload)
        sku = payload['sku'].presence
        hash = {
            'source_id'         => payload['variant_id'],
            'source_variant_id' => payload['variant_id'],
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
            'category'          => payload['category'],
            'variant_option_one_name' => payload['option_name'],
            'variant_option_one_value' => payload['option_value']
        }

        hash[:id] = payload['id'] if payload.has_key?('id')

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