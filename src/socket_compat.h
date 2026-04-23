#pragma once
/* Cross-platform socket headers for libssh2 integration */
#ifdef _WIN32
/* winsock2.h is already included by libssh2.h; add ws2tcpip.h for getaddrinfo */
#include <ws2tcpip.h>
#else
#include <sys/socket.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <unistd.h>
#endif
