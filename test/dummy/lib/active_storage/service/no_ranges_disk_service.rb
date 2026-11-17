# frozen_string_literal: true

require "active_storage/service/disk_service"

module ActiveStorage
  class Service
    # Stands in for a third-party service without ranged reads: the base class raises
    # NotImplementedError from download_chunk.
    class NoRangesDiskService < DiskService
      def download_chunk(_key, _range)
        raise NotImplementedError, "download_chunk is not supported by this service"
      end
    end
  end
end
