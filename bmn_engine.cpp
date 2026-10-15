// Optional performance extension point for BMN.
// Keep the deployed web app lightweight; only compile this when a native
// workload genuinely benefits from C++ (for example, media/data processing).
#include <string>
struct BMNEngineInfo { std::string name{"BMN Native Engine"}; std::string version{"10.0"}; };
