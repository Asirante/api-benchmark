-- 1. 독립적인 테이블 생성 (참조를 '받는' 부모 테이블들)
CREATE TABLE olist_geolocation_dataset (
    geolocation_zip_code_prefix VARCHAR(10),
    geolocation_lat FLOAT8,
    geolocation_lng FLOAT8,
    geolocation_city VARCHAR(50),
    geolocation_state VARCHAR(2)
);

CREATE TABLE olist_customers_dataset (
    customer_id VARCHAR(50) PRIMARY KEY,
    customer_unique_id VARCHAR(50),
    customer_zip_code_prefix VARCHAR(10),
    customer_city VARCHAR(50),
    customer_state VARCHAR(2)
);

CREATE TABLE olist_sellers_dataset (
    seller_id VARCHAR(50) PRIMARY KEY,
    seller_zip_code_prefix VARCHAR(10),
    seller_city VARCHAR(50),
    seller_state VARCHAR(2)
);

CREATE TABLE olist_products_dataset (
    product_id VARCHAR(50) PRIMARY KEY,
    product_category_name VARCHAR(50),
    product_name_length INT,
    product_description_length INT,
    product_photos_qty INT,
    product_weight_g INT,
    product_length_cm INT,
    product_height_cm INT,
    product_width_cm INT
);

CREATE TABLE product_category_name_translation (
    product_category_name VARCHAR(50) PRIMARY KEY,
    product_category_name_english VARCHAR(50)
);

-- 2. 1차 종속 테이블 생성 (고객 정보를 참조)
CREATE TABLE olist_orders_dataset (
    order_id VARCHAR(50) PRIMARY KEY,
    customer_id VARCHAR(50) REFERENCES olist_customers_dataset(customer_id),
    order_status VARCHAR(20),
    order_purchase_timestamp TIMESTAMP,
    order_approved_at TIMESTAMP,
    order_delivered_carrier_date TIMESTAMP,
    order_delivered_customer_date TIMESTAMP,
    order_estimated_delivery_date TIMESTAMP
);

-- 3. 2차 종속 테이블 생성 (주문, 상품, 판매자 정보를 모두 참조)
CREATE TABLE olist_order_items_dataset (
    order_id VARCHAR(50) REFERENCES olist_orders_dataset(order_id),
    order_item_id INT,
    product_id VARCHAR(50) REFERENCES olist_products_dataset(product_id),
    seller_id VARCHAR(50) REFERENCES olist_sellers_dataset(seller_id),
    shipping_limit_date TIMESTAMP,
    price FLOAT8,
    freight_value FLOAT8,
    PRIMARY KEY (order_id, order_item_id)
);

CREATE TABLE olist_order_payments_dataset (
    order_id VARCHAR(50) REFERENCES olist_orders_dataset(order_id),
    payment_sequential INT,
    payment_type VARCHAR(20),
    payment_installments INT,
    payment_value FLOAT8
);

CREATE TABLE olist_order_reviews_dataset (
    review_id VARCHAR(50),
    order_id VARCHAR(50) REFERENCES olist_orders_dataset(order_id),
    review_score INT,
    review_comment_title TEXT,
    review_comment_message TEXT,
    review_creation_date TIMESTAMP,
    review_answer_timestamp TIMESTAMP
);

-- 4. CSV 데이터 초고속 적재 (COPY 명령어)
COPY olist_geolocation_dataset FROM '/data/olist_geolocation_dataset.csv' DELIMITER ',' CSV HEADER;
COPY olist_customers_dataset FROM '/data/olist_customers_dataset.csv' DELIMITER ',' CSV HEADER;
COPY olist_sellers_dataset FROM '/data/olist_sellers_dataset.csv' DELIMITER ',' CSV HEADER;
COPY olist_products_dataset FROM '/data/olist_products_dataset.csv' DELIMITER ',' CSV HEADER;
COPY product_category_name_translation FROM '/data/product_category_name_translation.csv' DELIMITER ',' CSV HEADER;
COPY olist_orders_dataset FROM '/data/olist_orders_dataset.csv' DELIMITER ',' CSV HEADER;
COPY olist_order_items_dataset FROM '/data/olist_order_items_dataset.csv' DELIMITER ',' CSV HEADER;
COPY olist_order_payments_dataset FROM '/data/olist_order_payments_dataset.csv' DELIMITER ',' CSV HEADER;
COPY olist_order_reviews_dataset FROM '/data/olist_order_reviews_dataset.csv' DELIMITER ',' CSV HEADER;

-- 5. API 벤치마킹 성능 최적화를 위한 핵심 인덱스 생성
CREATE INDEX idx_orders_customer_id ON olist_orders_dataset(customer_id);
CREATE INDEX idx_order_items_order_id ON olist_order_items_dataset(order_id);
CREATE INDEX idx_order_items_product_id ON olist_order_items_dataset(product_id);
CREATE INDEX idx_order_items_seller_id ON olist_order_items_dataset(seller_id);
CREATE INDEX idx_order_payments_order_id ON olist_order_payments_dataset(order_id);
CREATE INDEX idx_order_reviews_order_id ON olist_order_reviews_dataset(order_id);
CREATE INDEX idx_geolocation_zip_code ON olist_geolocation_dataset(geolocation_zip_code_prefix);