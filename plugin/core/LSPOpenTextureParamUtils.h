#pragma once

#include <cstring>
#include <string>

inline bool paramLeafIs(const std::string& p_Name, const char* p_Leaf) {
    const size_t n = std::strlen(p_Leaf);
    if (n == 0)
        return false;
    if (p_Name.size() < n)
        return false;
    if (p_Name.size() == n)
        return p_Name == p_Leaf;
    if (p_Name.size() < n + 1u)
        return false;
    const char s = p_Name[p_Name.size() - n - 1u];
    if (s != '/' && s != '.')
        return false;
    return p_Name.compare(p_Name.size() - n, n, p_Leaf) == 0;
}
