#include "usbdevice.h"
#include <boost/asio/error.hpp>

namespace mobsya {

usb_device_service::usb_device_service(boost::asio::io_context& io_context)
    : boost::asio::detail::service_base<usb_device_service>(io_context)
    , m_context(details::usb_context::acquire_context()) {}

void usb_device_service::shutdown() {
    m_context = nullptr;
}

void usb_device_service::construct(implementation_type& impl) {
    impl.device = nullptr;
}

void usb_device_service::move_construct(implementation_type& impl, implementation_type& other_impl) {
    impl = other_impl;
}

void usb_device_service::destroy(implementation_type& impl) {
    libusb_unref_device(impl.device);
}

void usb_device_service::assign(implementation_type& impl, libusb_device* d) {
    close(impl);
    impl.device = d;
    libusb_ref_device(d);
}


void usb_device_service::cancel(implementation_type& impl) {}

void usb_device_service::close(implementation_type& impl) {
    if(impl.handle) {
        libusb_close(impl.handle);
        m_context->mark_not_open(impl.device);
        impl.handle = nullptr;
    }
    impl.in_address = impl.out_address = impl.read_size = impl.write_size = 0;
}

bool usb_device_service::is_open(implementation_type& impl) {
    return impl.handle != nullptr;
}

usb_device_service::native_handle_type usb_device_service::native_handle(implementation_type& impl) {
    return impl.device;
}

std::size_t usb_device_service::write_channel_chunk_size(const implementation_type& impl) const {
    return impl.write_size;
}

std::size_t usb_device_service::read_channel_chunk_size(const implementation_type& impl) const {
    return impl.read_size;
}

tl::expected<void, boost::system::error_code> usb_device_service::open(implementation_type& impl) {
    if(impl.handle)
        return tl::make_unexpected(boost::asio::error::already_open);

    impl.in_address = impl.out_address = impl.read_size = impl.write_size = 0;
    auto res = libusb_open(impl.device, &impl.handle);
    if(res != LIBUSB_SUCCESS) {
        return usb::make_unexpected(res);
    }
    m_context->mark_open(impl.device);

    libusb_reset_device(impl.handle);

    for(int if_num = 0; if_num < 2; if_num++) {
        if(libusb_kernel_driver_active(impl.handle, if_num)) {
            if(auto r = libusb_detach_kernel_driver(impl.handle, if_num)) {
                return usb::make_unexpected(r);
            }
        }
        if((res = libusb_claim_interface(impl.handle, if_num))) {
            return usb::make_unexpected(res);
        }
    }

    libusb_config_descriptor* desc;
    if(auto r = libusb_get_active_config_descriptor(impl.device, &desc)) {
        return usb::make_unexpected(r);
    }
    for(int i = 0; i < desc->bNumInterfaces; i++) {
        const auto interface = desc->interface[i];
        for(int s = 0; s < interface.num_altsetting; s++) {
            if(interface.altsetting[s].bInterfaceClass != LIBUSB_CLASS_DATA)
                continue;
            for(int e = 0; e < interface.altsetting[s].bNumEndpoints; e++) {
                const auto endpoint = interface.altsetting[s].endpoint[e];
                if(endpoint.bmAttributes & LIBUSB_TRANSFER_TYPE_BULK) {
                    if((endpoint.bEndpointAddress & LIBUSB_ENDPOINT_IN) == LIBUSB_ENDPOINT_IN) {
                        impl.in_address = endpoint.bEndpointAddress;
                        impl.read_size = endpoint.wMaxPacketSize;
                    } else if((endpoint.bEndpointAddress & LIBUSB_ENDPOINT_OUT) == LIBUSB_ENDPOINT_OUT) {
                        impl.out_address = endpoint.bEndpointAddress;
                        impl.write_size = endpoint.wMaxPacketSize;
                    }
                }
            }
        }
    }
    if(impl.in_address == 0 || impl.out_address == 0 || impl.read_size == 0 || impl.write_size == 0) {
        close(impl);
        return usb::make_unexpected(usb::error_code::not_found);
    }

    libusb_control_transfer(impl.handle, 0x21, 0x22, 0, 0, nullptr, 0, 0);
    libusb_control_transfer(impl.handle, 0x21, 0x22, 3, 0, nullptr, 0, 0);
    libusb_control_transfer(impl.handle, 0x21, 0x22, 0, 0, nullptr, 0, 0);
    libusb_clear_halt(impl.handle, impl.in_address);
    libusb_clear_halt(impl.handle, impl.out_address);


    send_control_transfer(impl);
    send_encoding(impl);
    return {};
}

void usb_device_service::set_baud_rate(implementation_type& impl, baud_rate b) {
    unsigned br = static_cast<unsigned>(b);
    impl.control_line[0] = uint8_t(br & 0xff);
    impl.control_line[1] = uint8_t((br >> 8) & 0xff);
    impl.control_line[2] = uint8_t((br >> 16) & 0xff);
    impl.control_line[3] = uint8_t((br >> 24) & 0xff);
    send_encoding(impl);
}

void usb_device_service::set_parity(implementation_type& impl, parity p) {
    impl.control_line[5] = static_cast<unsigned char>(p);
    send_encoding(impl);
}

void usb_device_service::set_data_bits(implementation_type& impl, data_bits b) {
    impl.control_line[6] = static_cast<unsigned char>(b);
    send_encoding(impl);
}

void usb_device_service::set_stop_bits(implementation_type& impl, stop_bits b) {
    impl.control_line[4] = static_cast<unsigned char>(b);
    send_encoding(impl);
}

void usb_device_service::set_data_terminal_ready(implementation_type& impl, bool dtr) {
    impl.dtr = dtr;
    send_control_transfer(impl);
}

bool usb_device_service::send_control_transfer(implementation_type& impl) {
    if(!is_open(impl))
        return false;
    uint16_t v = 0;
    if(impl.dtr)
        v |= 0x01;
    if(libusb_control_transfer(impl.handle, 0x21, 0x22, v, 0, nullptr, 0, 0) != LIBUSB_SUCCESS) {
        return false;
    }
    return true;
}

bool usb_device_service::send_encoding(implementation_type& impl) {
    if(!is_open(impl))
        return false;
    if(libusb_control_transfer(impl.handle, 0x21, 0x20, 0, 0, impl.control_line.data(), impl.control_line.size(), 0) !=
       LIBUSB_SUCCESS) {
        return false;
    }
    return true;
}

usb_device::usb_device(boost::asio::io_context& io_context)
    : boost::asio::basic_io_object<usb_device_service>(io_context) {}

void usb_device::assign(native_handle_type d) {
    this->get_service().assign(this->get_implementation(), d);
}

void usb_device::open() {
    this->get_service().open(this->get_implementation());
}

void usb_device::cancel() {
    this->get_service().cancel(this->get_implementation());
}

void usb_device::close() {
    this->get_service().close(this->get_implementation());
}

bool usb_device::is_open() {
    return this->get_service().is_open(this->get_implementation());
}

usb_device::native_handle_type usb_device::native_handle() {
    return this->get_service().native_handle(this->get_implementation());
}

std::size_t usb_device::write_channel_chunk_size() const {
    return this->get_service().write_channel_chunk_size(this->get_implementation());
}

std::size_t usb_device::read_channel_chunk_size() const {
    return this->get_service().read_channel_chunk_size(this->get_implementation());
}


void usb_device::set_baud_rate(baud_rate v) {
    this->get_service().set_baud_rate(this->get_implementation(), v);
}
void usb_device::set_data_bits(data_bits v) {
    this->get_service().set_data_bits(this->get_implementation(), v);
}

void usb_device::set_stop_bits(stop_bits v) {
    this->get_service().set_stop_bits(this->get_implementation(), v);
}

void usb_device::set_parity(parity v) {
    this->get_service().set_parity(this->get_implementation(), v);
}

void usb_device::set_data_terminal_ready(bool v) {
    this->get_service().set_data_terminal_ready(this->get_implementation(), v);
}


}  // namespace mobsya