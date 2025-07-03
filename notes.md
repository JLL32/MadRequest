# Notes on HTTP servers

## Closing client connection
- http 1.1 keep connections open by default
- check Connection header
  - if "close" is present, close connection
  - if not present, keep connection open
- include Content-Length header in response
- if the server wants to close the connection:
  - set "Connection: close" in response headers
  - close the socket after sending the response
  - ensure to flush the output buffer before closing
  - if using a TCP socket, ensure to:
    - send a FIN packet to indicate no more data will be sent
    - wait for an ACK from the client before fully closing the socket
- send FIN packet
