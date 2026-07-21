//
//  PacketTunnelProvider+FileDescriptor.h
//  YggdrasilTunnel
//
//  Apple SDK does not surface these utun control structures/constants to Swift,
//  so we declare them here and expose them via the bridging header.
//
#ifndef YggdrasilTunnel_FileDescriptor_h
#define YggdrasilTunnel_FileDescriptor_h

#include <stdint.h>
#include <sys/types.h>

// SPDX-License-Identifier: MIT
// Copyright © 2018-2023 WireGuard LLC. All Rights Reserved.
// Original source: https://github.com/WireGuard/wireguard-apple
//   Sources/WireGuardKitC/WireGuardKitC.h
#define CTLIOCGINFO 0xc0644e03UL
struct ctl_info {
    u_int32_t   ctl_id;
    char        ctl_name[96];
};
struct sockaddr_ctl {
    u_char      sc_len;
    u_char      sc_family;
    u_int16_t   ss_sysaddr;
    u_int32_t   sc_id;
    u_int32_t   sc_unit;
    u_int32_t   sc_reserved[5];
};

#endif /* YggdrasilTunnel_FileDescriptor_h */
