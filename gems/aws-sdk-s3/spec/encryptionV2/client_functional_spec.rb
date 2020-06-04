require_relative '../spec_helper'
require 'base64'
require 'openssl'

module Aws
  module S3
    module EncryptionV2

      describe Client do

        # Captures the data (metadata and body) put to an s3 object
        def stub_put(s3_client)
          data = {}
          s3_client.stub_responses(:put_object, ->(context) {
            data[:metadata] = context.params[:metadata]
            data[:enc_body] = context.params[:body].read
            {}
          })
          data
        end

        # Given data from stub_put, stub a get for the same object
        def stub_get(s3_client, data, stub_auth_tag)
          resp_headers = data[:metadata].map { |k, v| ["x-amz-meta-#{k.to_s}", v] }.to_h
          resp_headers['content-length'] = data[:enc_body].length
          if stub_auth_tag
            auth_tag = data[:enc_body].unpack('C*')[-16, 16].pack('C*')
          else
            auth_tag = nil
          end
          s3_client.stub_responses(
            :get_object,
            {status_code: 200, body: data[:enc_body], headers: resp_headers},
            {body: auth_tag}
          )
        end

        let(:plaintext) { 'super secret plain text' }
        let(:test_bucket) { 'test_bucket' }
        let(:test_object) { 'test_object' }

        let(:s3_client) { S3::Client.new(stub_responses: true) }

        context 'when using a symmetric (AES) key' do
          let(:key) do
            OpenSSL::Cipher::AES.new(256, :GCM).random_key
            #Base64.decode64("xmcwx8x67G2hbjRTsalme9ddO45hRIWrATTqcvqn5xk=\n")
          end

          it 'can encrypt and decrypt plain text' do
            client = Aws::S3::EncryptionV2::Client.new(encryption_key: key, client: s3_client)
            data = stub_put(s3_client)
            client.put_object(bucket: test_bucket, key: test_object, body: plaintext)
            expect(data[:metadata]['x-amz-cek-alg']).to eq('AES/GCM/NoPadding')
            expect(data[:metadata]['x-amz-wrap-alg']).to eq('AES/GCM')

            stub_get(s3_client, data, true)
            decrypted = client.get_object(bucket: test_bucket, key: test_object).body.read
            expect(decrypted).to eq(plaintext)
          end

          it 'can can use envelope_location: instruction_file' do
            client = Aws::S3::EncryptionV2::Client.new(
              encryption_key: key, client: s3_client, envelope_location: :instruction_file)
            data = {}
            s3_client.stub_responses(:put_object, ->(context) {
              if context.params[:key].include? '.instruction'
                data[:metadata] = JSON.load(context.params[:body])
              else
                data[:enc_body] = context.params[:body].read
              end
              {}
            })
            client.put_object(bucket: test_bucket, key: test_object, body: plaintext)

            resp_headers = { 'content-length' => data[:enc_body].length }
            auth_tag = data[:enc_body].unpack('C*')[-16, 16].pack('C*')

            s3_client.stub_responses(
              :get_object,
              {status_code: 200, body: data[:enc_body], headers: resp_headers},
              {body: Json.dump(data[:metadata])},
              {body: auth_tag}
            )
            decrypted = client.get_object(bucket: test_bucket, key: test_object).body.read
            expect(decrypted).to eq(plaintext)
          end

          it 'can decrypt an object encrypted using old algorithm' do
            client_v1 = Aws::S3::Encryption::Client.new(encryption_key: key, client: s3_client)
            client_v2 = Aws::S3::EncryptionV2::Client.new(encryption_key: key, client: s3_client)

            data = stub_put(s3_client)
            client_v1.put_object(bucket: test_bucket, key: test_object, body: plaintext)

            stub_get(s3_client, data, false)
            decrypted = client_v2.get_object(bucket: test_bucket, key: test_object).body.read
            expect(decrypted).to eq(plaintext)
          end

          # Error cases
          it 'raises a DecryptionError when the envelope is missing' do
            client = Aws::S3::EncryptionV2::Client.new(encryption_key: key, client: s3_client)
            stub_get(s3_client, {metadata: {}, enc_body: 'encrypted'}, false)
            expect do
              client.get_object(bucket: test_bucket, key: test_object)
            end.to raise_exception(Errors::DecryptionError,
                                   /unable to locate encryption envelope/)
          end

          it 'raises a DecryptionError when given an unsupported cek algorithm' do
            client = Aws::S3::EncryptionV2::Client.new(encryption_key: key, client: s3_client)
            data = stub_put(s3_client)
            client.put_object(bucket: test_bucket, key: test_object, body: plaintext)
            data[:metadata]['x-amz-cek-alg'] = 'BAD/ALG'

            stub_get(s3_client, data, true)
            expect do
              client.get_object(bucket: test_bucket, key: test_object)
            end.to raise_exception(Errors::DecryptionError,
                                   /unsupported content encrypting key/)
          end

          it 'raises a DecryptionError when given an unsupported wrap algorithm' do
            client = Aws::S3::EncryptionV2::Client.new(encryption_key: key, client: s3_client)
            data = stub_put(s3_client)
            client.put_object(bucket: test_bucket, key: test_object, body: plaintext)
            data[:metadata]['x-amz-wrap-alg'] = 'BAD/ALG'

            stub_get(s3_client, data, true)
            expect do
              client.get_object(bucket: test_bucket, key: test_object)
            end.to raise_exception(Errors::DecryptionError,
                                   /unsupported key wrapping algorithm/)
          end

          it 'raises a DecryptionError when the envelope is missing fields' do
            client = Aws::S3::EncryptionV2::Client.new(encryption_key: key, client: s3_client)
            data = stub_put(s3_client)
            client.put_object(bucket: test_bucket, key: test_object, body: plaintext)
            data[:metadata].delete('x-amz-iv')

            stub_get(s3_client, data, true)
            expect do
              client.get_object(bucket: test_bucket, key: test_object)
            end.to raise_exception(Errors::DecryptionError,
                                   /incomplete v2 encryption envelope/)
          end

          it 'raises an DecryptionError when a bit in the encrypted content modified' do
            client = Aws::S3::EncryptionV2::Client.new(encryption_key: key, client: s3_client)
            data = stub_put(s3_client)
            client.put_object(bucket: test_bucket, key: test_object, body: plaintext)
            data[:enc_body][0] = [(~data[:enc_body].unpack('C1')[0] << 1)].pack('C1')

            stub_get(s3_client, data, true)
            expect do
              client.get_object(bucket: test_bucket, key: test_object)
            end.to raise_exception(OpenSSL::Cipher::CipherError)
          end
        end

        context 'when using an asymmetric (RSA) key' do
          let(:key) do
            OpenSSL::PKey::RSA.new(1024)
          end

          it 'can encrypt and decrypt plain text' do
            client = Aws::S3::EncryptionV2::Client.new(encryption_key: key, client: s3_client)

            data = stub_put(s3_client)
            client.put_object(bucket: test_bucket, key: test_object, body: plaintext)
            expect(data[:metadata]['x-amz-cek-alg']).to eq('AES/GCM/NoPadding')
            expect(data[:metadata]['x-amz-wrap-alg']).to eq('RSA-OAEP-SHA1')

            stub_get(s3_client, data, true)
            decrypted = client.get_object(bucket: test_bucket, key: test_object).body.read
            expect(decrypted).to eq(plaintext)
          end

          it 'can decrypt an object encrypted using old algorithm' do
            client_v1 = Aws::S3::Encryption::Client.new(encryption_key: key, client: s3_client)
            client_v2 = Aws::S3::EncryptionV2::Client.new(encryption_key: key, client: s3_client)

            data = stub_put(s3_client)
            client_v1.put_object(bucket: test_bucket, key: test_object, body: plaintext)

            stub_get(s3_client, data, false)
            decrypted = client_v2.get_object(bucket: test_bucket, key: test_object).body.read
            expect(decrypted).to eq(plaintext)
          end
        end

        context 'when using a KMS Key' do
          let(:kms_client) { KMS::Client.new(stub_responses: true) }
          let(:kms_key_id) { 'kms_key_id' }
          let(:kms_ciphertext_blob) do
            Base64.decode64("AQIDAHiWj6qDEnwihp7W7g6VZb1xqsat5jdSUdEaGhgZepHdLAGASCQI7LZz\nz7GzCpm6y4sHAAAAfjB8BgkqhkiG9w0BBwagbzBtAgEAMGgGCSqGSIb3DQEH\nATAeBglghkgBZQMEAS4wEQQMJMJe6d8DkRTWwlvtAgEQgDtBCwiibCTS8pb7\n6BYKklVjy+CmO9q3r6y4u/9jJ8lk9eg5GwiskmcBtPMcWogMzx/vh+/65Cjb\nsQBpLQ==\n")
          end

          let(:kms_plaintext) do
            Base64.decode64("5V7JWe+UDRhv66TaDg+tP6JONf/GkTdXk6Jq61weM+w=\n")
          end

          it 'can encrypt and decrypt plain text' do
            client = Aws::S3::EncryptionV2::Client.new(
              kms_key_id: kms_key_id, client: s3_client, kms_client: kms_client)

            data = stub_put(s3_client)
            kms_client.stub_responses(
              :generate_data_key,
              {
                key_id: kms_key_id,
                ciphertext_blob: kms_ciphertext_blob,
                plaintext: kms_plaintext
              }
            )
            client.put_object(bucket: test_bucket, key: test_object, body: plaintext)
            expect(data[:metadata]['x-amz-cek-alg']).to eq('AES/GCM/NoPadding')
            expect(data[:metadata]['x-amz-wrap-alg']).to eq('kms+context')

            stub_get(s3_client, data, true)
            kms_client.stub_responses(
              :decrypt,
              {
                key_id: kms_key_id,
                plaintext: kms_plaintext,
                encryption_algorithm: "SYMMETRIC_DEFAULT"
              }
            )
            decrypted = client.get_object(bucket: test_bucket, key: test_object).body.read
            expect(decrypted).to eq(plaintext)
          end

          it 'can decrypt an object encrypted using old algorithm' do
            client_v1 = Aws::S3::Encryption::Client.new(
              kms_key_id: kms_key_id, client: s3_client, kms_client: kms_client)
            client_v2 = Aws::S3::EncryptionV2::Client.new(
              kms_key_id: kms_key_id, client: s3_client, kms_client: kms_client)

            data = stub_put(s3_client)
            kms_client.stub_responses(
              :generate_data_key,
              {
                key_id: kms_key_id,
                ciphertext_blob: kms_ciphertext_blob,
                plaintext: kms_plaintext
              }
            )
            client_v1.put_object(bucket: test_bucket, key: test_object, body: plaintext)

            stub_get(s3_client, data, true)
            kms_client.stub_responses(
              :decrypt,
              {
                key_id: kms_key_id,
                plaintext: kms_plaintext,
                encryption_algorithm: "SYMMETRIC_DEFAULT"
              }
            )
            decrypted = client_v2.get_object(bucket: test_bucket, key: test_object).body.read
            expect(decrypted).to eq(plaintext)
          end

          it 'raises a DecryptionError when the cek_alg has been modified' do
            client = Aws::S3::EncryptionV2::Client.new(
              kms_key_id: kms_key_id, client: s3_client, kms_client: kms_client)

            data = stub_put(s3_client)
            kms_client.stub_responses(
              :generate_data_key,
              {
                key_id: kms_key_id,
                ciphertext_blob: kms_ciphertext_blob,
                plaintext: kms_plaintext
              }
            )
            client.put_object(bucket: test_bucket, key: test_object, body: plaintext)
            data[:metadata]['x-amz-cek-alg'] = 'AES/CBC/PKCS5Padding'

            stub_get(s3_client, data, true)
            kms_client.stub_responses(
              :decrypt,
              {
                key_id: kms_key_id,
                plaintext: kms_plaintext,
                encryption_algorithm: "SYMMETRIC_DEFAULT"
              }
            )
            expect do
              client.get_object(bucket: test_bucket, key: test_object)
            end.to raise_exception(Errors::DecryptionError, /oes not match the value in the encryption context/)

          end
        end
      end
    end
  end
end
