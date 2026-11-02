#pragma once
#ifdef __cplusplus
extern "C" {
#endif
// UTF-8 JSON request/result. The caller owns the result until Free is called.
char *SouloED2KCommand(const char *request);
void SouloED2KFree(char *result);
#ifdef __cplusplus
}
#endif
