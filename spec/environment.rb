CarrierWave.configure do |config|
  config.azure_storage_account_name = ENV['STORAGE_ACCOUNT_NAME']
  config.azure_storage_access_key = ENV['STORAGE_ACCESS_KEY']
  config.azure_container = ENV['CONTAINER_NAME']
  config.azure_default_expiry = ENV['DEFAULT_EXPIRY']
end
