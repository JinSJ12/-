import MLX

/// AI가 쓰는 메모리를 관리합니다.
enum AIMemory {
    /// 모델은 그대로 두고, 다시 쓰려고 남겨 둔 임시 메모리만 비웁니다.
    /// 메모리 한도를 낮추지 않으므로 평소 번역 속도에는 영향이 없습니다.
    static func refresh() {
        Memory.clearCache()
    }
}
